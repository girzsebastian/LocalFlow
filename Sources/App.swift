import SwiftUI
import AppKit
import AVFoundation
import Speech
import Carbon
import UniformTypeIdentifiers

@MainActor final class Store: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var preferences = Preferences()
    @Published var selection: UUID?
    @Published var page = "Dictation"
    @Published var status = "Ready when you are"
    @Published var error: String?
    @Published var widgetNotice: String?
    @Published var correctionSuggestion: CorrectionSuggestion?
    @Published var liveTranscriptStatus = "Waiting for speech…"
    @Published var streamedPhraseCount = 0
    @Published var recording = false
    @Published var audioLevel: Float = 0
    @Published var handsFree = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    var permissionTimer: Timer?
    @Published var activityStart: Date?
    var gesture = ShortcutGesture()
    var releaseTask: Task<Void, Never>?
    var widgetNoticeTask: Task<Void, Never>?
    var correctionTask: Task<Void, Never>?
    var correctionExpiryTask: Task<Void, Never>?
    var liveTranscriptTask: Task<Void, Never>?
    var streamingDictationTask: Task<Void, Never>?
    var streamedPhrases: [(offset: Double, text: String)] = []
    var streamedThrough = 0.0
    var lastDictationVoiceTime = 0.0
    var startingRecording = false
    var pendingStop = false
    var jobID: UUID?
    var lastExternalApp: NSRunningApplication?
    var activationObserver: NSObjectProtocol?
    @Published var busy = false
    @Published var aiBusy = false
    @Published var started: Date?
    @Published var languages: [String] = ["en-US"]
    @Published var claudeStatus = "Check connection in Settings"
    let root = AppPaths.root
    let whisperServer = WhisperServer()
    let languageServer = WhisperServer(model: WhisperTranscription.detectorModel, portOffset: 1, audioContext: 256, detectsOnly: true)
    lazy var speech = WhisperTranscription(server: whisperServer, detector: languageServer)
    let claude = ClaudeBridge()
    let liveSpeech = LiveMeetingTranscription()
    lazy var streamingSpeech = StreamingDictationTranscription(server: whisperServer, detector: languageServer)
    let outputMute = OutputMute()
    let calendar = CalendarSupport()
    let notifications = MeetingNotifications()
    static weak var instance: Store?
    var floating: FloatingControl?
    var meter: Timer?
    var mouseHook: MouseShortcut?
    var mouseMonitor: Any?
    var localMouseMonitor: Any?
    var meetingAudio: MeetingAudio?
    var recorder: MicrophoneRecorder?
    var player: AVAudioPlayer?
    var activeID: UUID?
    var target: PasteDestination?
    var hotkey: EventHotKeyRef?
    var noteHotkey: EventHotKeyRef?
    var noteKeyDown = false
    var handler: EventHandlerRef?
    var archiveHealthy = true
    var transcriptionTask: Task<Void, Never>?
    init() {
        Self.instance = self
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            let file = root.appendingPathComponent("archive.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                entries = archive.entries; preferences = archive.preferences
            }
        } catch { archiveHealthy = false; self.error = "Could not load your library. Existing files will not be overwritten: \(error.localizedDescription)" }
        if preferences.snippets == "my email => your@email.com" { preferences.snippets = ""; save() }
        if preferences.pasteConfigured == nil { preferences.autoPaste = true; preferences.pasteConfigured = true; save() }
        if preferences.notetakerConfigured == nil {
            preferences.captureSystem = true
            preferences.notetakerConfigured = true
            save()
        }
        // Back-fill the portable shortcut for archives written before KeyChord
        // existed. The Carbon fields stay authoritative on this build.
        if preferences.shortcutChord == nil, preferences.shortcutMouse == nil,
           let chord = KeyChord(displayLabel: preferences.shortcutLabel ?? "⌃⇧Space") {
            preferences.shortcutChord = chord
            save()
        }
        notifications.start(store: self)
        calendar.lead = preferences.meetingReminderSeconds ?? 15
        if preferences.calendarEnabled == true { calendar.start() }
        languages = ["auto", "en-US", "ro-RO"]
        if preferences.multilingualConfigured == nil { preferences.locale = "auto"; preferences.multilingualConfigured = true; save() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier { lastExternalApp = frontmost }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in if app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.lastExternalApp = app } }
        }
        Task { floating = FloatingControl(store: self); floating?.show(); applySystemPreferences() }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer else { return noErr }
            let store = Unmanaged<Store>.fromOpaque(pointer).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            let note = hotkeyID.id == 2
            Task { @MainActor in
                if note {
                    if down && !store.noteKeyDown { store.noteKeyDown = true; store.toggle(kind: "Notetaker") }
                    if !down { store.noteKeyDown = false }
                }
                else if down { store.shortcutDown() } else { store.shortcutUp() }
            }
            return noErr
        }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(optionKey), EventHotKeyID(signature: 0x4C464C57, id: 2), GetApplicationEventTarget(), 0, &noteHotkey)
        registerShortcut(); writeDiagnostics()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let allowed = AXIsProcessTrusted()
                if allowed != self.accessibilityGranted {
                    self.accessibilityGranted = allowed
                    self.registerShortcut(); self.writeDiagnostics()
                    if !self.recording && !self.busy { self.status = allowed ? "Accessibility enabled · automatic paste ready" : "Enable Accessibility for automatic paste" }
                }
            }
        }
    }
    func showPage(_ name: String) {
        if name == "Scratchpad" && preferences.scratchpadBehavior == "New note", !preferences.scratchpad.isEmpty {
            entries.insert(Entry(title: "Scratchpad · \(Date().formatted(date: .abbreviated, time: .shortened))", kind: "Notetaker", transcript: preferences.scratchpad), at: 0)
            preferences.scratchpad = ""; save()
        }
        page = name; selection = nil
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }
    func writeDiagnostics() {
        // Read from the bundle rather than hardcoding: the literal that used to
        // sit here said "0.2" through two releases, so every diagnostics file a
        // user sent reported the wrong version.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let data: [String: Any] = ["version": version, "accessibility": AXIsProcessTrusted(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "modelInstalled": FileManager.default.fileExists(atPath: WhisperTranscription.model.path), "date": ISO8601DateFormatter().string(from: Date())]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) { try? json.write(to: root.appendingPathComponent("diagnostics.json"), options: .atomic) }
    }
    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func notifyWidget(_ message: String, for seconds: Double = 5) {
        widgetNotice = message
        widgetNoticeTask?.cancel()
        widgetNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard self?.widgetNotice == message else { return }
            self?.widgetNotice = nil
        }
    }
    func watchForCorrection(in destination: PasteDestination, original: String) {
        correctionTask?.cancel()
        correctionExpiryTask?.cancel()
        correctionSuggestion = nil
        guard preferences.suggestCorrections != false else { return }
        correctionTask = Task { [weak self] in
            guard let self, let baseline = await destination.correctionBaseline(for: original) else { return }
            var latest = baseline.text
            var changedAt: Date?
            for _ in 0..<50 {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let current = destination.textValue() else { return }
                if current != latest {
                    latest = current
                    changedAt = Date()
                    continue
                }
                guard let changedAt, Date().timeIntervalSince(changedAt) >= 1.0 else { continue }
                if let suggestion = CorrectionWordDiff.suggestion(baseline: baseline.text, edited: latest, insertedRange: baseline.range) {
                    presentCorrection(suggestion)
                    return
                }
            }
        }
    }
    func presentCorrection(_ suggestion: CorrectionSuggestion) {
        correctionSuggestion = suggestion
        correctionExpiryTask?.cancel()
        correctionExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard self?.correctionSuggestion == suggestion else { return }
            self?.correctionSuggestion = nil
        }
    }
    func acceptCorrection() {
        guard let suggestion = correctionSuggestion else { return }
        let rule = "\(suggestion.original) => \(suggestion.corrected)"
        let existing = preferences.dictionary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !existing.contains(where: { $0.caseInsensitiveCompare(rule) == .orderedSame }) {
            if !preferences.dictionary.isEmpty, !preferences.dictionary.hasSuffix("\n") { preferences.dictionary += "\n" }
            preferences.dictionary += rule
            save()
        }
        correctionSuggestion = nil
        notifyWidget("Added to Dictionary: \(rule)")
    }
    var shortcutName: String { preferences.shortcutLabel ?? "⌃⇧Space" }
    func registerShortcut() {
        mouseHook?.stop(); mouseHook = nil
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let button = preferences.shortcutMouse {
            if AXIsProcessTrusted() {
                mouseHook = MouseShortcut(button: button) { [weak self] down in
                    if down { self?.shortcutDown() } else { self?.shortcutUp() }
                }
                if mouseHook != nil { return }
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                if event.buttonNumber == button { Task { @MainActor in if event.type == .otherMouseDown { self?.shortcutDown() } else { self?.shortcutUp() } } }
            }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                if event.buttonNumber == button { if event.type == .otherMouseDown { self?.shortcutDown() } else { self?.shortcutUp() }; return nil }
                return event
            }
        } else {
            let result = RegisterEventHotKey(preferences.shortcutCode ?? UInt32(kVK_Space), preferences.shortcutModifiers ?? UInt32(controlKey | shiftKey), EventHotKeyID(signature: 0x4C464C57, id: 1), GetApplicationEventTarget(), 0, &hotkey)
            if result != noErr { error = "That shortcut is already in use. Choose a different shortcut in Settings." }
        }
    }
    func setShortcut(code: UInt32? = nil, modifiers: UInt32? = nil, mouse: Int? = nil, label: String) {
        preferences.shortcutCode = code; preferences.shortcutModifiers = modifiers
        preferences.shortcutMouse = mouse; preferences.shortcutLabel = label
        // Recorded in both forms: Carbon drives this build, the chord travels.
        preferences.shortcutChord = mouse == nil ? KeyChord(displayLabel: label) : nil
        save(); registerShortcut()
    }

    func save() {
        guard archiveHealthy else { return }
        do { try JSONEncoder().encode(Archive(entries: entries, preferences: preferences)).write(to: root.appendingPathComponent("archive.json"), options: .atomic) }
        catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
    func update(_ id: UUID, _ action: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        action(&entries[i]); save()
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func shortcutDown() {
        guard !busy || startingRecording else { return }
        if recording && gesture.phase == .idle { gesture.latch() }
        handleGesture(gesture.down(at: ProcessInfo.processInfo.systemUptime))
    }
    func shortcutUp() { handleGesture(gesture.up(at: ProcessInfo.processInfo.systemUptime)) }
    func handleGesture(_ actions: [ShortcutGesture.Action]) {
        for action in actions {
            switch action {
            case .start: handsFree = false; beginRecording(kind: "Dictation", external: true)
            case .stop:
                if startingRecording { pendingStop = true } else { stop() }
            case .latch: handsFree = true; status = "Hands-free recording · press \(shortcutName) to finish"
            case .scheduleRelease:
                releaseTask?.cancel()
                releaseTask = Task {
                    do { try await Task.sleep(for: .seconds(gesture.doubleTapWindow)) } catch { return }
                    handleGesture(gesture.releaseExpired())
                }
            case .cancelRelease: releaseTask?.cancel(); releaseTask = nil
            }
        }
    }
    func toggle(kind: String, fromHotkey: Bool = false) {
        guard !busy else { return }
        if recording { stop(); return }
        gesture.latch(); handsFree = true
        beginRecording(kind: kind, external: fromHotkey)
    }
    func beginRecording(kind: String, external: Bool) {
        guard !busy && !recording else { return }
        correctionTask?.cancel(); correctionSuggestion = nil
        streamingDictationTask?.cancel(); streamingDictationTask = nil
        streamedPhrases = []; streamedThrough = 0; streamedPhraseCount = 0; lastDictationVoiceTime = 0
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApp : frontmost
        target = kind == "Dictation" && external ? PasteDestination.capture(application: app) : nil
        busy = true; startingRecording = true; pendingStop = false; activityStart = Date()
        status = "Starting microphone…"
        Task {
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw flowError("Allow Microphone access for LocalFlow in System Settings → Privacy & Security.") }
                let id = UUID()
                let fileName = kind == "Notetaker" ? "\(id)-mic.caf" : "\(id)-dictation.caf"
                let url = root.appendingPathComponent("Audio/\(fileName)")
                let audio = MacMicrophoneRecorder()
                if kind == "Notetaker" && preferences.captureSystem {
                    status = "Starting meeting audio capture…"
                    let meeting = MeetingAudio(destination: root.appendingPathComponent("Audio/\(id)-system.caf"))
                    try await meeting.start(); meetingAudio = meeting
                }
                // Mute before the microphone opens, so it never records playback.
                // A throw from start() lands in the catch below, which restores
                // the output and stops meeting capture.
                if kind == "Dictation" && preferences.muteWhileDictating != false { try outputMute.mute() }
                try audio.start(writingTo: url)
                recorder = audio; activeID = id; started = Date(); recording = true
                Task {
                    try? await languageServer.prepare()
                    try? await whisperServer.prepare()
                }
                entries.insert(Entry(id: id, title: "\(kind) · \(Date().formatted(date: .abbreviated, time: .shortened))", kind: kind, audio: url.lastPathComponent), at: 0)
                selection = id; page = kind; save()
                if kind == "Notetaker" { startLiveTranscript(id: id, microphone: url, system: preferences.captureSystem ? root.appendingPathComponent("Audio/\(id)-system.caf") : nil) }
                else { startStreamingDictation(id: id, source: url) }
                status = handsFree ? "Hands-free recording · press \(shortcutName) to finish" : "Recording · release \(shortcutName) to finish"
                meter = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let recorder = self.recorder else { return }
                        if self.outputMute.isEngaged { do { try self.outputMute.refreshForCurrentDevice() } catch { self.error = error.localizedDescription } }
                        if kind == "Notetaker", recorder.elapsed >= Double((self.preferences.maxNoteMinutes ?? 120) * 60) { self.stop(); return }
                        self.audioLevel = recorder.currentLevel()
                        if kind == "Dictation", self.audioLevel > 0.12 { self.lastDictationVoiceTime = recorder.elapsed }
                    }
                }
                busy = false; startingRecording = false; activityStart = nil
                if kind == "Notetaker" && preferences.openNotepad != false { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }
                if pendingStop { pendingStop = false; stop() }
            } catch {
                outputMute.restore()
                try? await meetingAudio?.stop(); meetingAudio = nil
                busy = false; startingRecording = false; activityStart = nil; gesture.reset(); handsFree = false
                self.error = error.localizedDescription; status = "Recording could not start"
            }
        }
    }
    func stop() {
        guard recording else { return }
        liveTranscriptTask?.cancel(); liveTranscriptTask = nil
        streamingDictationTask?.cancel(); streamingDictationTask = nil
        outputMute.restore()
        releaseTask?.cancel(); releaseTask = nil; gesture.reset(); handsFree = false
        // Prefer the field active at stop; retain the original field if LocalFlow has focus.
        if target != nil, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            target = PasteDestination.capture(application: frontmost)
        }
        meter?.invalidate(); meter = nil; audioLevel = 0
        let duration = recorder?.stop()
        recorder = nil; recording = false; started = nil
        guard let id = activeID else { return }; activeID = nil
        update(id) { $0.duration = duration; $0.applicationName = target?.application.localizedName }
        if let meeting = meetingAudio {
            let microphone = entries.first(where: { $0.id == id })?.audio.map { root.appendingPathComponent("Audio/\($0)") }
            meetingAudio = nil; busy = true; status = "Saving meeting audio…"
            Task {
                do {
                    try await meeting.stop()
                    let system = root.appendingPathComponent("Audio/\(id)-system.caf")
                    if FileManager.default.fileExists(atPath: system.path) {
                        update(id) { $0.systemAudio = system.lastPathComponent }
                        let combined = root.appendingPathComponent("Audio/\(id)-meeting.m4a")
                        guard let microphone else { throw flowError("The microphone recording could not be found.") }
                        try await MeetingAudio.mix(microphone: microphone, system: system, destination: combined)
                        update(id) { $0.audio = combined.lastPathComponent }
                    }
                } catch { self.error = "System audio could not be combined. Your microphone recording is saved. \(error.localizedDescription)" }
                busy = false; transcribe(id)
            }
        } else if entries.first(where: { $0.id == id })?.kind == "Dictation" {
            let prefix = streamedPhrases.sorted { $0.offset < $1.offset }.map(\.text).joined(separator: " ")
            transcribe(id, paste: target != nil, streamedPrefix: prefix, streamedOffset: streamedThrough)
        } else {
            transcribe(id)
        }
    }

    /// Finalizes each completed spoken phrase while the microphone keeps recording.
    /// The final Stop path then sends only the uncommitted tail to Whisper.
    func startStreamingDictation(id: UUID, source: URL) {
        streamingDictationTask?.cancel()
        streamedPhrases = []; streamedThrough = 0; streamedPhraseCount = 0; lastDictationVoiceTime = 0
        let locale = preferences.locale
        let vocabulary = preferences.dictionary.split(separator: "\n").map {
            String($0).components(separatedBy: "=>").last!.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        streamingDictationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, recording, activeID == id {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }

                guard let recorder, recorder.isRecording else { return }
                let now = recorder.elapsed
                let voiceEnd = lastDictationVoiceTime
                // Wait for a real phrase followed by a natural pause. A little
                // trailing room avoids clipping the final consonant.
                guard voiceEnd - streamedThrough >= 0.45, now - voiceEnd >= 0.75 else { continue }
                let phraseEnd = min(now, voiceEnd + 0.25)
                let phraseStart = streamedThrough
                status = "Recording · transcribing phrase \(streamedPhraseCount + 1) in background…"
                do {
                    let text = try await streamingSpeech.transcribe(
                        source: source,
                        start: phraseStart,
                        duration: phraseEnd - phraseStart,
                        locale: locale,
                        hints: vocabulary
                    )
                    try Task.checkCancellation()
                    guard recording, activeID == id else { return }
                    streamedThrough = phraseEnd
                    if !text.isEmpty {
                        streamedPhrases.append((offset: phraseEnd, text: text))
                        streamedPhraseCount = streamedPhrases.count
                    }
                    status = streamedPhraseCount == 1
                        ? "Recording · 1 phrase ready"
                        : "Recording · \(streamedPhraseCount) phrases ready"
                } catch is CancellationError {
                    return
                } catch {
                    // Preserve the uncommitted audio for the final pass. Avoid a
                    // retry loop while the user is still speaking.
                    status = "Recording · this phrase will finish after Stop"
                    return
                }
            }
        }
    }
    func transcribe(_ id: UUID, paste: Bool = false, streamedPrefix: String = "", streamedOffset: Double = 0) {
        guard !busy, let entry = entries.first(where: { $0.id == id }), let audio = entry.audio else { return }
        busy = true; status = "Preparing local transcription…"; activityStart = Date()
        let operation = UUID(); jobID = operation
        let locale = preferences.locale
        let destination = target
        transcriptionTask = Task {
            defer { if jobID == operation { busy = false; transcriptionTask = nil; jobID = nil; activityStart = nil } }
            do {
                let vocabulary = preferences.dictionary.split(separator: "\n").map { String($0).components(separatedBy: "=>").last!.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let source = root.appendingPathComponent("Audio/\(audio)")
                let raw: String
                if streamedOffset > 0, !streamedPrefix.isEmpty {
                    status = "Finishing the last spoken phrase…"
                    let total = entries.first(where: { $0.id == id })?.duration ?? streamedOffset
                    let tail = try await streamingSpeech.transcribe(source: source, start: streamedOffset,
                                                                     duration: max(0, total - streamedOffset), locale: locale, hints: vocabulary)
                    raw = [streamedPrefix, tail].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    raw = try await speech.transcribe(source, locale: locale, hints: vocabulary) { message in
                        await MainActor.run { if self.jobID == operation { self.status = message } }
                    }
                }
                try Task.checkCancellation()
                guard jobID == operation else { return }
                let expanded = expand(expand(raw, rules: preferences.dictionary), rules: preferences.snippets)
                var text = expanded
                if entry.kind == "Dictation", preferences.cleanDictation == true, !expanded.isEmpty {
                    // Opt-in Claude pass. Any failure falls back to the literal transcript so
                    // dictation never blocks on Claude.
                    status = "Cleaning up with Claude…"
                    do {
                        if let cleaned = try await claude.cleanDictation(expanded), cleaned != expanded {
                            text = cleaned
                            update(id) { $0.rawTranscript = expanded }
                        }
                    } catch {
                        notifyWidget("Claude cleanup skipped · pasted the raw dictation")
                    }
                    try Task.checkCancellation()
                    guard jobID == operation else { return }
                }
                update(id) { $0.transcript = text }
                if entry.kind == "Dictation" {
                    copy(text)
                    status = "Dictation copied · paste with Command V"
                    if paste && preferences.autoPaste, let destination {
                        status = try await destination.insert(text)
                        watchForCorrection(in: destination, original: text)
                    }

                } else { status = "Note transcribed and saved" }
                if preferences.sounds == true { NSSound(named: "Pop")?.play() }
                if entry.kind == "Notetaker" && preferences.autoInsights { transform(id, mode: "Meeting insights") }
            } catch is CancellationError { if jobID == operation { status = "Transcription cancelled · audio saved" } }
            catch { if jobID == operation { self.error = error.localizedDescription; status = "Needs attention · transcript/audio saved" } }
        }
    }
    func cancelTranscription() {
        outputMute.restore()
        transcriptionTask?.cancel(); transcriptionTask = nil; jobID = nil
        busy = false; activityStart = nil; gesture.reset()
        status = "Transcription cancelled · audio saved"
        notifyWidget("Transcription cancelled. Your audio is saved.")
    }
    func transform(_ id: UUID, mode: String) {
        guard !aiBusy, let entry = entries.first(where: { $0.id == id }), !entry.transcript.isEmpty else { return }
        aiBusy = true; status = "Claude is working…"
        let instruction: String
        switch mode {
        case "Meeting insights": instruction = "Create meeting notes with headings: Summary, Decisions, Action items, Open questions. Only name owners or deadlines if stated. Mark uncertain information. Do not infer speaker identities."
        case "Apply style": instruction = "Edit this transcript using this style: \(preferences.style). Preserve all facts."
        default: instruction = preferences.transformer
        }
        Task {
            defer { aiBusy = false }
            do {
                let result = try await claude.transform(text: entry.transcript, instruction: instruction)
                update(id) { $0.insights = result }; status = "Claude result saved · original transcript preserved"
            } catch { self.error = error.localizedDescription; status = "Claude needs attention" }
        }
    }
    func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true; status = "Importing audio…"
        Task {
            defer { busy = false }
            do {
                let id = UUID(), destination = root.appendingPathComponent("Audio/\(UUID()).m4a")
                let asset = AVURLAsset(url: source)
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw flowError("This file cannot be imported.") }
                try await export.export(to: destination, as: .m4a)
                entries.insert(Entry(id: id, title: source.deletingPathExtension().lastPathComponent, kind: "Notetaker", audio: destination.lastPathComponent), at: 0)
                selection = id; page = "Notetaker"; save(); status = "Audio imported · choose Transcribe"
            } catch { self.error = error.localizedDescription }
        }
    }
    func play(_ entry: Entry) {
        guard let file = entry.audio else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: root.appendingPathComponent("Audio/\(file)")); player?.play() }
        catch { self.error = error.localizedDescription }
    }
    func export(_ entry: Entry, audio: Bool = false) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = audio ? "Recording.m4a" : "\(entry.title.replacingOccurrences(of: "/", with: "-" )).md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data: Data
            if audio, let file = entry.audio { data = try Data(contentsOf: root.appendingPathComponent("Audio/\(file)")) }
            else { data = Data("# \(entry.title)\n\n\(entry.transcript)\n\n## Insights\n\n\(entry.insights)".utf8) }
            try data.write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
    func checkClaude() { Task { do { claudeStatus = try await claude.status() } catch { claudeStatus = error.localizedDescription } } }
    func login() {
        let command = "#!/bin/zsh\n\"$HOME/.local/bin/claude\" auth login\n"
        let url = root.appendingPathComponent("Sign in to Claude.command")
        do { try command.write(to: url, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path); NSWorkspace.shared.open(url) }
        catch { self.error = error.localizedDescription }
    }
}

@main struct LocalFlowApp: App {
    @StateObject var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("LocalFlow") { ContentView().environmentObject(store).frame(minWidth: 980, minHeight: 650).onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.save() } }
        MenuBarExtra { Button(store.recording ? "Stop recording" : "Dictate · \(store.shortcutName)") { store.toggle(kind: "Dictation") }; Button("Record a note") { store.toggle(kind: "Notetaker") }.disabled(store.recording || store.busy); Divider(); Button("Open LocalFlow") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }; Button("Quit") { NSApp.terminate(nil) }.disabled(store.recording || store.busy) } label: { FlowMenuLabel(store: store, calendar: store.calendar) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Store.instance?.outputMute.restore()
        _ = Store.instance?.recorder?.stop()
        Store.instance?.save()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Store.instance else { return .terminateNow }
        Task {
            await store.whisperServer.stop()
            await store.languageServer.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
