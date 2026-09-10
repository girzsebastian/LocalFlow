import SwiftUI


extension Store {
    func askNotes(_ question: String) {
        guard !aiBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let notes = entries.filter { $0.kind == "Notetaker" && !$0.transcript.isEmpty }.prefix(20)
        guard !notes.isEmpty else { error = "Transcribe a note first, then ask a question about it."; return }
        let context = notes.map { "NOTE: \($0.title)\nDATE: \($0.date.formatted())\n\($0.transcript.prefix(10000))\n" }.joined(separator: "\n---\n")
        aiBusy = true; status = "Claude is checking your saved notes…"
        Task {
            defer { aiBusy = false }
            do {
                let answer = try await claude.transform(text: context, instruction: "Answer this user's question using only the supplied notes: \(question). Cite the note title for each factual claim. Say when the notes do not contain the answer. Preserve the language of the question.")
                var chats = preferences.noteChats ?? []
                chats.insert(NoteExchange(question: question, answer: answer), at: 0)
                preferences.noteChats = Array(chats.prefix(50)); save(); status = "Answer saved in note chat history"
            } catch { self.error = error.localizedDescription; status = "Claude could not answer" }
        }
    }
    func generateVoiceProfile() {
        guard !aiBusy else { return }
        let dictations = entries.filter { $0.kind == "Dictation" && !$0.transcript.isEmpty }.prefix(30)
        guard !dictations.isEmpty else { error = "Create a few dictations first so there is writing to analyze."; return }
        let context = dictations.map { String($0.transcript.prefix(3000)) }.joined(separator: "\n---\n")
        aiBusy = true; status = "Claude is analyzing your writing patterns…"
        Task {
            defer { aiBusy = false }
            do {
                let result = try await claude.transform(text: context, instruction: "Create a concise writing-style profile based only on these dictations. Include observed languages, tone, sentence structure, repeated specialist vocabulary, and practical writing suggestions. Explain that this describes transcript writing patterns, not acoustic voice traits. Do not infer personality, identity, health, or demographics. Acknowledge limited samples and avoid rankings against other users.")
                preferences.voiceProfile = result; preferences.voiceProfileDate = Date(); save(); status = "Writing profile saved"
            } catch { self.error = error.localizedDescription; status = "Profile could not be generated" }
        }
    }
}

struct InsightsView: View {
    @EnvironmentObject var s: Store
    @State var tab = "Your usage"
    var summary: UsageSummary { UsageSummary(entries: s.entries) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Insights", selection: $tab) { Text("Your usage").tag("Your usage"); Text("Your writing profile").tag("Your writing profile") }.pickerStyle(.segmented).frame(width: 340)
                if tab == "Your usage" {
                    HStack(spacing: 16) {
                        metric("Words dictated", value: "\(summary.totalWords)", icon: "text.word.spacing")
                        metric("Words per minute", value: summary.wordsPerMinute.map(String.init) ?? "—", icon: "speedometer")
                        metric("Current streak", value: "\(summary.currentStreak) days", icon: "flame")
                    }
                    Text("Counts come from your Softspoke library. Speaking speed uses recordings with measured duration; earlier recordings may not have it.").font(.caption).foregroundStyle(.secondary)
                    GroupBox("Recent activity · 6 weeks") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 14), spacing: 6) {
                            ForEach(0..<42, id: \.self) { index in
                                let date = Calendar.current.date(byAdding: .day, value: index - 41, to: Calendar.current.startOfDay(for: Date()))!
                                RoundedRectangle(cornerRadius: 5).fill(summary.activeDays.contains(date) ? Color.mint : Color.secondary.opacity(0.12)).frame(height: 28).help(date.formatted(date: .abbreviated, time: .omitted))
                            }
                        }.padding(16)
                    }
                    GroupBox("Apps you dictate into") {
                        VStack(spacing: 12) {
                            if summary.apps.isEmpty { Text("Your app usage will appear after your first dictation.").foregroundStyle(.secondary) }
                            ForEach(summary.apps.prefix(8), id: \.0) { app in
                                HStack { Text(app.0).frame(width: 180, alignment: .leading); ProgressView(value: Double(app.1), total: Double(max(1, summary.dictations.count))); Text("\(app.1)").monospacedDigit() }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("The way you put things into words.").font(.system(size: 30, design: .serif))
                        Text("Ask Claude to find writing patterns in your last 30 dictations. This analyzes text, not the sound of your voice.").foregroundStyle(.secondary)
                        Button(s.preferences.voiceProfile == nil ? "Create writing profile" : "Regenerate profile") { s.generateVoiceProfile() }.buttonStyle(.borderedProminent).disabled(s.aiBusy)
                        if let date = s.preferences.voiceProfileDate { Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        if let report = s.preferences.voiceProfile { Text(report).textSelection(.enabled).lineSpacing(5); Button("Copy profile") { s.copy(report) } }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Color.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding(28)
        }
    }
    func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Image(systemName: icon).foregroundStyle(.mint); Text(value).font(.system(size: 30, weight: .semibold)); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct NotesQuestionView: View {
    @EnvironmentObject var s: Store
    @State var question = ""
    @State var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Ask your notes: what do I need to follow up on?", text: $question).textFieldStyle(.roundedBorder).onSubmit { s.askNotes(question) }
                Button("Ask Claude") { s.askNotes(question) }.disabled(s.aiBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Past chats") { showHistory.toggle() }
            }
            Text("Answers use your latest 20 transcribed notes, up to 10,000 characters each.").font(.caption2).foregroundStyle(.secondary)
            if showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(s.preferences.noteChats ?? []) { chat in
                            DisclosureGroup(chat.question) { Text(chat.answer).textSelection(.enabled).padding(.top, 8); Button("Copy answer") { s.copy(chat.answer) } }
                        }
                        if (s.preferences.noteChats ?? []).isEmpty { Text("No questions yet.").foregroundStyle(.secondary) }
                    }
                }.frame(maxHeight: 200)
            } else if let chat = s.preferences.noteChats?.first {
                DisclosureGroup("Latest answer: \(chat.question)") { Text(chat.answer).textSelection(.enabled).padding(.top, 8) }
            }
        }.padding(.horizontal, 20).padding(.bottom, 14)
    }
}
