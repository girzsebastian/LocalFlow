import SwiftUI
import AppKit
import Combine
import Carbon

final class VoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class WidgetAppearance: ObservableObject {
    @Published var collapsed = true
}
@MainActor final class FloatingControl {
    let appearance = WidgetAppearance()
    private var lastHover = Date.distantPast
    let panel: VoicePanel
    unowned let store: Store
    private var subscription: AnyCancellable?
    private var noticeSubscription: AnyCancellable?
    private var correctionSubscription: AnyCancellable?
    private var followTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var currentScreen: NSScreen?
    init(store: Store) {
        self.store = store
        panel = VoicePanel(contentRect: NSRect(x: 12, y: 350, width: 48, height: 184), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: FloatingView(appearance: appearance).environmentObject(store))
        // The controller owns window geometry. Hosting minimum-size constraints can
        // stretch the old content while switching between the handle and toolbar.
        hosting.sizingOptions = []
        panel.contentView = hosting
        followPointer(force: true)
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followPointer() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.followPointer(force: true) }
        }
        subscription = Publishers.CombineLatest4(store.$recording, store.$busy, store.$error, store.$preferences).sink { [weak self] recording, busy, error, preferences in
            guard let self else { return }
            Task { @MainActor in self.updateVisibility() }
        }
        noticeSubscription = store.$widgetNotice.sink { [weak self] _ in
            Task { @MainActor in self?.updateVisibility() }
        }
        correctionSubscription = store.$correctionSuggestion.sink { [weak self] _ in
            Task { @MainActor in self?.updateVisibility() }
        }
    }
    func followPointer(force: Bool = false) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
        if force || screen != currentScreen { currentScreen = screen; lastHover = .distantPast }
        let hoverArea = panel.frame.insetBy(dx: -12, dy: -10)
        if hoverArea.contains(mouse) { lastHover = Date() }
        updateVisibility()
    }
    func updateVisibility() {
        guard let screen = currentScreen else { return }
        let active = store.recording || store.busy || store.error != nil || store.widgetNotice != nil || store.correctionSuggestion != nil
        guard active || store.preferences.showWidgetAlways != false else { panel.orderOut(nil); return }
        // Tracking menus use a different run-loop mode; retain the expanded controls until they close.
        let menuOpen = RunLoop.current.currentMode == .eventTracking
        let collapsed = !active && store.preferences.autoHideWidget != false && !menuOpen && Date().timeIntervalSince(lastHover) > 0.9
        let width: CGFloat = collapsed ? 10 : active ? 280 : 48
        let height: CGFloat = collapsed ? 48 : 184
        let frame = NSRect(x: screen.visibleFrame.minX + (collapsed ? 2 : 10), y: screen.visibleFrame.midY - height / 2, width: width, height: height)
        if appearance.collapsed != collapsed || panel.frame != frame {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            appearance.collapsed = collapsed
            panel.setFrame(frame, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            NSAnimationContext.endGrouping()
        }
        panel.orderFrontRegardless()
    }
    func show() { followPointer(force: true); updateVisibility() }
    deinit { followTimer?.invalidate(); if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) } }
}
struct FloatingView: View {
    @EnvironmentObject var s: Store
    @ObservedObject var appearance: WidgetAppearance
    var body: some View {
        Group {
            if appearance.collapsed {
                Capsule().fill(Color.gray.opacity(0.55)).frame(width: 5, height: 38)
                    .frame(width: 10, height: 48).help("Softspoke · move here to dictate")
            } else {
                controls.frame(width: s.recording || s.busy || s.error != nil || s.widgetNotice != nil || s.correctionSuggestion != nil ? 280 : 48, height: 184, alignment: .leading)
            }
        }.clipped().environment(\.colorScheme, .dark)
         .transaction { $0.animation = nil }
    }
    var controls: some View {
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                Menu {
                    Button("Multilingual · English + Romanian") { s.preferences.locale = "auto"; s.save() }
                    Button("English") { s.preferences.locale = "en-US"; s.save() }
                    Button("Română") { s.preferences.locale = "ro-RO"; s.save() }
                } label: { Image(systemName: "globe").font(.system(size: 17)).foregroundStyle(.mint).frame(width: 28, height: 22) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 30).help("Spoken language")

                Button { s.toggle(kind: "Dictation", fromHotkey: true) } label: {
                    Image(systemName: s.recording ? "stop.fill" : "mic.fill").foregroundStyle(s.recording ? Color.red : .white).frame(width: 34, height: 34).background(s.recording ? Color.red.opacity(0.12) : .white.opacity(0.08), in: Circle())
                }.help(s.recording ? "Stop recording" : "Dictate · \(s.shortcutName)").disabled(s.busy)
                Button { s.toggle(kind: "Notetaker") } label: { Image(systemName: "record.circle").foregroundStyle(.white).frame(width: 34, height: 32) }.help("New note · ⌥M").disabled(s.recording || s.busy)
                Button { s.showPage("Scratchpad") } label: { Image(systemName: "square.and.pencil").foregroundStyle(.white.opacity(0.8)).frame(width: 34, height: 30) }.help("Open scratchpad")
            }.font(.system(size: 17)).buttonStyle(.plain).padding(.vertical, 10).frame(width: 44, height: 180).background(.black.opacity(0.9), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.18)))
            if s.recording || s.busy || s.error != nil || s.widgetNotice != nil || s.correctionSuggestion != nil {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle().fill(s.recording ? Color.red : .mint).frame(width: 5, height: 5)
                        Text(s.recording ? (s.handsFree ? "Hands-free" : "Listening") : s.busy ? "Processing" : s.error != nil ? "Needs attention" : s.correctionSuggestion != nil ? "Learn this correction?" : "Softspoke").font(.system(size: 11, weight: .medium))
                        Spacer()
                        if s.recording { TimelineView(.periodic(from: .now, by: 1)) { context in Text(String(format: "%02d:%02d", Int(context.date.timeIntervalSince(s.started ?? context.date)) / 60, Int(context.date.timeIntervalSince(s.started ?? context.date)) % 60)).font(.system(size: 10, design: .monospaced)) } }
                    }
                    if s.error != nil && !s.recording && !s.busy {
                        Text(s.error ?? "").font(.caption).lineLimit(4)
                        HStack {
                            if s.error?.localizedCaseInsensitiveContains("Accessibility") == true {
                                Button("Open Settings") { s.openAccessibilitySettings() }.controlSize(.small)
                            }
                            Button("Dismiss") { s.error = nil }.controlSize(.small)
                        }
                    } else if let correction = s.correctionSuggestion, !s.recording && !s.busy {
                        Text("“\(correction.original)” → “\(correction.corrected)”").font(.caption.weight(.medium)).lineLimit(3)
                        HStack {
                            Button("Add to Dictionary") { s.acceptCorrection() }.controlSize(.small)
                            Button("No thanks") { s.correctionSuggestion = nil }.controlSize(.small)
                        }
                    } else if let notice = s.widgetNotice, !s.recording && !s.busy {
                        Text(notice).font(.caption).lineLimit(4)
                        Button("Dismiss") { s.widgetNotice = nil }.controlSize(.small)
                    } else if s.busy {
                        Text(s.status).font(.caption).lineLimit(3)
                        HStack {
                            ProgressView().controlSize(.mini)
                            TimelineView(.periodic(from: .now, by: 1)) { context in Text("\(max(0, Int(context.date.timeIntervalSince(s.activityStart ?? context.date))))s").font(.caption.monospacedDigit()) }
                            Spacer()
                            if s.transcriptionTask != nil { Button("Cancel") { s.cancelTranscription() }.controlSize(.small) }
                        }
                    }
                    else if s.audioLevel < 0.12 { Text("…").font(.system(size: 22, weight: .medium)).tracking(4).frame(maxWidth: .infinity).frame(height: 28).foregroundStyle(.white.opacity(0.7)) }
                    else {
                        TimelineView(.animation(minimumInterval: 0.07)) { context in
                            let time = context.date.timeIntervalSinceReferenceDate
                            HStack(spacing: 3) {
                                ForEach(0..<24, id: \.self) { index in
                                    Capsule().fill(Color.mint).frame(width: 3, height: barHeight(time: time, index: index))
                                }
                            }.frame(maxWidth: .infinity).frame(height: 28)
                        }
                    }
                    Text(recordingFooter).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }.foregroundStyle(.white).padding(12).frame(width: 220).background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 15))
            }
        }.fixedSize(horizontal: true, vertical: true).padding(.leading, 2)
    }

    var recordingFooter: String {
        guard s.recording else {
            return s.error != nil ? "Your audio is saved" : s.correctionSuggestion != nil ? "Available for 8 seconds" : "This message will close automatically"
        }
        let control = s.handsFree ? "Press \(s.shortcutName) to finish" : "Release to finish · double-tap to lock"
        guard s.streamedPhraseCount > 0 else { return control }
        return "\(s.streamedPhraseCount) phrase\(s.streamedPhraseCount == 1 ? "" : "s") ready · \(control)"
    }
}
extension FloatingView {
    func barHeight(time: Double, index: Int) -> CGFloat {
        let oscillation = abs(sin(time * 9 + Double(index) * 0.8))
        return CGFloat(max(3.0, Double(s.audioLevel) * (10.0 + 18.0 * oscillation)))
    }
}
struct ShortcutSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var monitor: Any?
    @State var hint = "Press a key combination, or click an extra mouse button."
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard").font(.system(size: 36)).foregroundStyle(.mint)
            Text("Choose your dictation shortcut").font(.title2.bold())
            Text(hint).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack { Button("Mouse 4") { store.setShortcut(mouse: 3, label: "Mouse 4"); dismiss() }; Button("Mouse 5") { store.setShortcut(mouse: 4, label: "Mouse 5"); dismiss() }; Button("Reset to ⌃⇧Space") { store.setShortcut(label: "⌃⇧Space"); dismiss() } }
            Button("Cancel") { store.notifyWidget("Shortcut change cancelled."); dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(32).frame(width: 470)
        .onAppear {
            // Temporarily release the old shortcut so it can be recorded again.
            store.mouseHook?.stop(); store.mouseHook = nil
            if let hotkey = store.hotkey { UnregisterEventHotKey(hotkey); store.hotkey = nil }
            if let local = store.localMouseMonitor { NSEvent.removeMonitor(local); store.localMouseMonitor = nil }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
                if event.type == .otherMouseDown {
                    store.setShortcut(mouse: event.buttonNumber, label: "Mouse \(event.buttonNumber + 1)"); dismiss(); return nil
                }
                if event.keyCode == 53 { store.notifyWidget("Shortcut change cancelled."); dismiss(); return nil }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { hint = "Include Control, Option, or Command with your key."; return nil }
                var modifiers: UInt32 = 0, label = ""
                if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
                if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
                if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
                if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
                label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
                store.setShortcut(code: UInt32(event.keyCode), modifiers: modifiers, label: label); dismiss(); return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; store.registerShortcut() }
    }
}
