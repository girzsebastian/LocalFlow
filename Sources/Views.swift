import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var s: Store
    @State private var search = ""
    @State private var captureShortcut = false
    @State private var hoveredPage: String?
    let pages = [("Dictation", "waveform"), ("Notetaker", "note.text"), ("Insights", "chart.bar"), ("Dictionary", "character.book.closed"), ("Snippets", "text.badge.plus"), ("Style", "textformat"), ("Transformers", "wand.and.stars"), ("Scratchpad", "square.and.pencil"), ("Settings", "gearshape")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "waveform.circle.fill").font(.largeTitle).foregroundStyle(.mint); Text("Softspoke").font(.title2.bold()) }.padding(.vertical, 22)
                Text("YOUR VOICE, YOUR WORKSPACE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).padding(.bottom, 14)
                ForEach(pages, id: \.0) { page in
                    Button { s.page = page.0; s.selection = nil } label: {
                        Label(page.0, systemImage: page.1).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(s.page == page.0 ? Color.mint.opacity(0.13) : hoveredPage == page.0 ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle()).onHover { hoveredPage = $0 ? page.0 : nil }
                    }.buttonStyle(.plain)
                }
                Spacer()
                Label("On-device transcription", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                // Third place the version was hardcoded, and the only one a user
                // ever sees. Read it from the bundle so it cannot drift again.
                Text("Personal preview · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).frame(width: 225).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(s.page).font(.system(size: 28, weight: .bold)); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    if s.recording { TimelineView(.periodic(from: .now, by: 1)) { context in Label(elapsed(context.date), systemImage: "record.circle.fill").foregroundStyle(.red).monospacedDigit() } }
                    if s.busy || s.aiBusy { ProgressView().controlSize(.small) }
                    if s.busy && s.transcriptionTask != nil { Button("Cancel") { s.cancelTranscription() } }
                }.padding(28)
                Divider()
                if s.page == "Notetaker", s.recording, let id = s.activeID { LiveNotetakerView(id: id).environmentObject(s) }
                else if ["Dictation", "Notetaker"].contains(s.page) { library } else if s.page == "Insights" { InsightsView().environmentObject(s) } else if s.page == "Settings" { PreferencesView() } else { settingsPage }
                Divider()
                HStack { Circle().fill(s.recording ? Color.red : Color.mint).frame(width: 6, height: 6); Text(s.status).lineLimit(2); Spacer(); Text(s.shortcutName).font(.system(.caption, design: .monospaced)) }.font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }.tint(.mint)
        .sheet(isPresented: $captureShortcut) { ShortcutSheet(store: s) }
        .onChange(of: s.preferences.locale) { s.save() }
    }
    var subtitle: String {
        switch s.page {
        case "Dictation": "Speak naturally. Keep your words close."
        case "Notetaker": "A home for conversations, ideas, and next steps."
        case "Scratchpad": "A little space to think out loud."
        case "Settings": "Make Softspoke feel like yours."
        default: "Small tools for the way you work."
        }
    }
    func elapsed(_ date: Date) -> String { let seconds = max(0, Int(date.timeIntervalSince(s.started ?? date))); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { s.toggle(kind: s.page) } label: { Label(s.recording ? "Stop & transcribe" : s.page == "Dictation" ? "Start dictation" : "Record a note", systemImage: s.recording ? "stop.fill" : "mic.fill") }.buttonStyle(.borderedProminent).disabled(s.busy)
                Button("Import audio / video") { s.importAudio() }.disabled(s.busy || s.recording)
                Spacer()
                TextField("Search your library", text: $search).textFieldStyle(.roundedBorder).frame(width: 210)
            }.padding(20)
            if s.page == "Notetaker" { UpcomingMeetingsView(calendar: s.calendar).environmentObject(s); NotesQuestionView().environmentObject(s) }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(s.entries.filter { $0.kind == s.page && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.transcript.localizedCaseInsensitiveContains(search)) }) { entry in
                            Button { s.selection = entry.id } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(entry.title).font(.headline).lineLimit(2)
                                    Text(entry.transcript.isEmpty ? "Audio saved · awaiting transcript" : entry.transcript).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(s.selection == entry.id ? Color.mint.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }.frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                if let id = s.selection, s.entries.contains(where: { $0.id == id }) { EntryView(id: id).environmentObject(s) }
                else {
                    VStack(spacing: 18) {
                        Image(systemName: s.page == "Dictation" ? "waveform" : "text.bubble").font(.system(size: 54, weight: .light)).foregroundStyle(.mint)
                        Text(s.page == "Dictation" ? "A thought is all it takes." : "Make room for the conversation.").font(.title2.bold())
                        Text(s.page == "Dictation" ? "Hold \(s.shortcutName) while speaking, then release to paste.\nDouble-tap for hands-free dictation." : "Record a meeting or import existing audio.\nGenerate summaries and action items with Claude.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Text("Audio stays on this Mac. Claude actions send transcript text to Claude.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
                }
            }
        }
    }
    var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch s.page {
                case "Scratchpad":
                    Text("Saved automatically on your Mac.").foregroundStyle(.secondary)
                    editor($s.preferences.scratchpad, height: 370)
                    Button("Save as note") { let e = Entry(title: "Scratchpad · \(Date().formatted(date: .abbreviated, time: .shortened))", kind: "Notetaker", transcript: s.preferences.scratchpad); s.entries.insert(e, at: 0); s.selection = e.id; s.page = "Notetaker"; s.save() }.disabled(s.preferences.scratchpad.isEmpty)
                case "Snippets":
                    Text("Expand spoken phrases into reusable text. One rule per line.").font(.headline)
                    Text("Example: my signature => Jane Doe, Acme\nRules apply after transcription, matching whole phrases.").foregroundStyle(.secondary)
                    editor($s.preferences.snippets)
                case "Dictionary":
                    Text("Teach transcription your names and specialist words.").font(.headline)
                    Text("One term per line. Optional correction: misheard phrase => correct spelling").foregroundStyle(.secondary)
                    editor($s.preferences.dictionary)
                case "Style":
                    Text("Choose the voice for Claude’s Apply style action.").font(.headline)
                    Picker("Writing style", selection: $s.preferences.style) { ForEach(["Keep my wording", "Casual and conversational", "Professional and concise", "Clear email with greeting and sign-off", "Organized bullet points"], id: \.self) { Text($0).tag($0) } }.onChange(of: s.preferences.style) { s.save() }
                    Text("Open a transcript and choose Apply style. The result appears separately from your original.").foregroundStyle(.secondary)
                case "Transformers":
                    Text("Your custom instruction for Claude").font(.headline)
                    editor($s.preferences.transformer)
                    Text("Use Run transformer on any saved transcript. For example: translate to Romanian, draft a follow-up email, or extract tasks.").foregroundStyle(.secondary)
                default: EmptyView()
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading)
        }
    }
    func editor(_ binding: Binding<String>, height: CGFloat = 230) -> some View {
        TextEditor(text: binding).font(.system(size: 15)).padding(10).frame(minHeight: height).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2))).onChange(of: binding.wrappedValue) { s.save() }
    }
}
struct EntryView: View {
    @EnvironmentObject var s: Store
    let id: UUID
    @State var confirmDelete = false
    var entry: Entry { s.entries.first(where: { $0.id == id }) ?? Entry(id: id, title: "", kind: "Notetaker") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Title", text: Binding(get: { entry.title }, set: { text in s.update(id) { $0.title = text } })).font(.title2.bold()).textFieldStyle(.plain)
                HStack {
                    Button("Play", systemImage: "play.fill") { s.play(entry) }.disabled(entry.audio == nil)
                    Button("Stop audio") { s.player?.stop() }
                    Button("Transcribe") { s.transcribe(id) }.disabled(s.busy || s.recording || entry.audio == nil)
                    Menu("Export") { Button("Markdown note") { s.export(entry) }; Button("Audio file") { s.export(entry, audio: true) }.disabled(entry.audio == nil) }
                }
                HStack { Text("TRANSCRIPT").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button("Copy") { s.copy(entry.transcript) }.disabled(entry.transcript.isEmpty) }
                TextEditor(text: Binding(get: { entry.transcript }, set: { text in s.update(id) { $0.transcript = text } })).font(.system(size: 15)).frame(minHeight: 220).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.15)))
                if let raw = entry.rawTranscript, !raw.isEmpty, raw != entry.transcript {
                    DisclosureGroup("Before Claude cleanup · literal dictation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(raw).textSelection(.enabled)
                            HStack {
                                Button("Copy literal") { s.copy(raw) }
                                Button("Restore literal") { s.update(id) { $0.transcript = raw; $0.rawTranscript = nil } }
                            }
                        }.padding(.top, 8)
                    }
                }
                if let segments = entry.meetingSegments, !segments.isEmpty {
                    DisclosureGroup("Speaker timeline · \(segments.count) live segments") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(segments.sorted { $0.offset < $1.offset }) { segment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(segment.speaker) · \(Int(segment.offset) / 60):\(String(format: "%02d", Int(segment.offset) % 60))").font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(segment.text).textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 8)
                    }
                }
                HStack {
                    Menu("Ask Claude") {
                        Button("Meeting insights") { s.transform(id, mode: "Meeting insights") }
                        Button("Apply style") { s.transform(id, mode: "Apply style") }
                        Button("Run transformer") { s.transform(id, mode: "Transformer") }
                    }.disabled(entry.transcript.isEmpty || s.aiBusy)
                    Text("Uses your Claude account").font(.caption).foregroundStyle(.secondary)
                }
                if !entry.insights.isEmpty {
                    HStack { Text("CLAUDE RESULT").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button("Copy result") { s.copy(entry.insights) } }
                    TextEditor(text: Binding(get: { entry.insights }, set: { text in s.update(id) { $0.insights = text } })).font(.system(size: 15)).frame(minHeight: 230).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.15)))
                }
                if let chats = entry.meetingChats, !chats.isEmpty {
                    DisclosureGroup("Questions about this meeting · \(chats.count)") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(chats) { chat in
                                VStack(alignment: .leading, spacing: 5) { Text(chat.question).font(.caption.bold()); Text(chat.answer).textSelection(.enabled) }
                            }
                        }.padding(.top, 8)
                    }
                }
                Spacer()
                Button("Remove from library", role: .destructive) { confirmDelete = true }.disabled(s.recording || s.busy || s.aiBusy)
            }.padding(24)
        }.frame(maxWidth: .infinity)
        .confirmationDialog("Remove this entry? The audio file will remain in your local Audio folder.", isPresented: $confirmDelete) { Button("Remove", role: .destructive) { s.selection = nil; s.entries.removeAll { $0.id == id }; s.save() } }
    }
}
