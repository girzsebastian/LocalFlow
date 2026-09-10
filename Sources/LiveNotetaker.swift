import SwiftUI

extension Store {
    func startLiveTranscript(id: UUID, microphone: URL, system: URL?) {
        liveTranscriptTask?.cancel()
        liveTranscriptStatus = FileManager.default.fileExists(atPath: LiveMeetingTranscription.model.path)
            ? "Listening for speech…" : "Live model missing · final transcript will still be created"
        guard FileManager.default.fileExists(atPath: LiveMeetingTranscription.model.path) else { return }
        liveTranscriptTask = Task { [weak self] in
            guard let self else { return }
            var micOffset = 0.0, systemOffset = 0.0
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            while !Task.isCancelled, recording, activeID == id {
                let captured = max(0, (recorder?.elapsed ?? 0) - 0.4)
                let hints = preferences.dictionary.split(separator: "\n").map {
                    String($0).components(separatedBy: "=>").last?.trimmingCharacters(in: .whitespaces) ?? ""
                }.filter { !$0.isEmpty }
                if captured - micOffset >= 2 {
                    let end = min(captured, micOffset + 14)
                    liveTranscriptStatus = "Updating what you said…"
                    do {
                        let result = try await liveSpeech.transcribe(source: microphone, start: micOffset, duration: end - micOffset, locale: preferences.locale, hints: hints)
                        micOffset = end
                        if case .speech(let text) = result { appendMeetingSegment(id: id, offset: end, speaker: "You", text: text) }
                    } catch is CancellationError { return }
                    catch { liveTranscriptStatus = "Your live transcript is catching up…" }
                }
                if let system, captured - systemOffset >= 2, FileManager.default.fileExists(atPath: system.path) {
                    let end = min(captured, systemOffset + 14)
                    liveTranscriptStatus = "Updating meeting participants…"
                    do {
                        let result = try await liveSpeech.transcribe(source: system, start: systemOffset, duration: end - systemOffset, locale: preferences.locale, hints: hints)
                        systemOffset = end
                        if case .speech(let text) = result { appendMeetingSegment(id: id, offset: end, speaker: "Meeting participants", text: text) }
                    } catch is CancellationError { return }
                    catch { liveTranscriptStatus = "Meeting audio live transcript is catching up…" }
                }
                liveTranscriptStatus = "Live transcript · final accuracy pass after Stop"
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    func appendMeetingSegment(id: UUID, offset: Double, speaker: String, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        update(id) { entry in
            var segments = entry.meetingSegments ?? []
            if segments.last?.speaker == speaker, segments.last?.text == cleaned { return }
            segments.append(MeetingSegment(offset: offset, speaker: speaker, text: cleaned))
            entry.meetingSegments = segments
        }
    }

    func meetingContext(_ id: UUID) -> String {
        guard let entry = entries.first(where: { $0.id == id }) else { return "" }
        if let segments = entry.meetingSegments, !segments.isEmpty {
            return segments.sorted { $0.offset < $1.offset }.map {
                let seconds = Int($0.offset)
                return String(format: "[%02d:%02d] %@: %@", seconds / 60, seconds % 60, $0.speaker, $0.text)
            }.joined(separator: "\n")
        }
        return entry.transcript
    }

    func summarizeMeetingSoFar(_ id: UUID) {
        guard !aiBusy else { return }
        let context = meetingContext(id)
        guard !context.isEmpty else { notifyWidget("Not enough meeting speech to summarize yet."); return }
        aiBusy = true; status = "Claude is summarizing the meeting so far…"
        Task {
            defer { aiBusy = false }
            do {
                let answer = try await claude.transform(text: context, instruction: "Summarize only the meeting transcript supplied so far. Use sections: Discussion, Decisions, My action items, Other action items, Open questions. Treat lines labelled You as the user's speech and Meeting participants as other people's speech. Do not invent names, owners or deadlines. Preserve the main language used by the transcript.")
                update(id) { $0.insights = answer }
                status = "Meeting summary updated"
            } catch { self.error = error.localizedDescription; status = "Claude could not summarize the meeting" }
        }
    }

    func askMeeting(_ id: UUID, question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aiBusy, !question.isEmpty else { return }
        let context = meetingContext(id)
        guard !context.isEmpty else { notifyWidget("Not enough meeting speech to answer yet."); return }
        aiBusy = true; status = "Claude is checking this meeting…"
        Task {
            defer { aiBusy = false }
            do {
                let answer = try await claude.transform(text: context, instruction: "Answer this question using only the supplied meeting transcript: \(question). Treat You as the user and Meeting participants as other people. If the transcript does not contain the answer, say so clearly. Do not invent details. Reply in the language of the question.")
                update(id) { entry in
                    var chats = entry.meetingChats ?? []
                    chats.append(NoteExchange(question: question, answer: answer))
                    entry.meetingChats = Array(chats.suffix(50))
                }
                status = "Meeting answer ready"
            } catch { self.error = error.localizedDescription; status = "Claude could not answer" }
        }
    }
}

struct LiveNotetakerView: View {
    @EnvironmentObject var s: Store
    let id: UUID
    @State private var question = ""
    var entry: Entry? { s.entries.first(where: { $0.id == id }) }
    var segments: [MeetingSegment] { (entry?.meetingSegments ?? []).sorted { $0.offset < $1.offset } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("Notetaker active", systemImage: "record.circle.fill").foregroundStyle(.red).font(.headline)
                Text(s.liveTranscriptStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Summarize so far", systemImage: "sparkles") { s.summarizeMeetingSoFar(id) }.disabled(s.aiBusy || segments.isEmpty)
                Button("Stop & finalize", systemImage: "stop.fill") { s.stop() }.buttonStyle(.borderedProminent)
            }.padding(18)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LIVE CONVERSATION").font(.caption.bold()).foregroundStyle(.secondary)
                    if segments.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("The first lines appear after a short speech segment.")
                            Text(s.preferences.captureSystem ? "You and meeting participants are captured separately." : "Only your microphone is enabled. Turn on meeting audio in Settings → Notetaker to include participants.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(segments) { segment in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { Text(segment.speaker).font(.caption.bold()).foregroundStyle(segment.speaker == "You" ? Color.mint : Color.orange); Spacer(); Text(format(segment.offset)).font(.caption2).foregroundStyle(.tertiary) }
                                        Text(segment.text).textSelection(.enabled)
                                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }.padding(18).frame(minWidth: 380)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("SUMMARY SO FAR").font(.caption.bold()).foregroundStyle(.secondary); if s.aiBusy { Spacer(); ProgressView().controlSize(.small) } }
                    ScrollView { Text(entry?.insights.isEmpty == false ? entry!.insights : "Use “Summarize so far” whenever you want decisions and action items from the discussion captured up to now.").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).foregroundStyle(entry?.insights.isEmpty == false ? .primary : .secondary) }
                        .frame(minHeight: 130)
                    Divider()
                    Text("ASK THIS MEETING").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(entry?.meetingChats ?? []) { chat in
                                VStack(alignment: .leading, spacing: 5) { Text(chat.question).font(.caption.bold()); Text(chat.answer).textSelection(.enabled) }
                                    .padding(10).background(Color.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                    HStack {
                        TextField("What do I need to do?", text: $question).textFieldStyle(.roundedBorder).onSubmit { ask() }
                        Button("Ask") { ask() }.disabled(s.aiBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18).frame(minWidth: 330)
            }
            Text("Live text uses a faster local model. After Stop, Softspoke runs the larger accuracy model over the saved recording.").font(.caption2).foregroundStyle(.secondary).padding(10)
        }
    }
    func ask() { let value = question; question = ""; s.askMeeting(id, question: value) }
    func format(_ offset: Double) -> String { let value = Int(offset); return String(format: "%02d:%02d", value / 60, value % 60) }
}
