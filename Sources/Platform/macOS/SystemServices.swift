import AppKit
import AVFoundation
import ServiceManagement

// The small OS services Softspoke needs, each behind its protocol from
// Sources/Core/PlatformCapabilities.swift.
//
// These were previously one-line calls scattered through App.swift —
// NSPasteboard here, NSSound there, an AXIsProcessTrusted() in a @Published
// property initializer. Individually harmless; collectively the reason the app
// state could not be constructed off macOS.

@MainActor final class MacClipboard: Clipboard {
    func setText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor final class MacSoundEffects: SoundEffects {
    func playCompletionSound() {
        NSSound(named: "Pop")?.play()
    }
}

/// Accessibility on macOS: the grant that lets Softspoke watch a global
/// shortcut and write text into another application.
@MainActor final class MacAutomationPermission: AutomationPermission {
    private var timer: Timer?

    var isAutomationTrusted: Bool { AXIsProcessTrusted() }

    func promptForAutomationTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// macOS sends no notification when the grant changes, so this polls. The
    /// second-long interval is what the app used before; it is cheap because
    /// AXIsProcessTrusted() is a local check, and it is the only way to notice
    /// the user flipping the switch in System Settings while the app runs.
    func observeTrustChanges(_ onChange: @escaping (Bool) -> Void) {
        timer?.invalidate()
        var last = AXIsProcessTrusted()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            guard now != last else { return }
            last = now
            onChange(now)
        }
    }
}

@MainActor final class MacMicrophonePermission: MicrophonePermission {
    var microphoneState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

@MainActor final class MacLaunchAtLogin: LaunchAtLogin {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ on: Bool) async throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}

@MainActor final class MacShellLauncher: ShellLauncher {
    /// Writes a short script and opens it, because `claude auth login` needs a
    /// real terminal: it prints a URL and waits for a pasted code, which a
    /// captured pipe cannot provide.
    func launchInteractiveTerminal(command: String, title: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title).command")
        try "#!/bin/zsh\n\(command)\n".write(to: url, atomically: true, encoding: .utf8)
        // 0o700: the file carries no secret, but it is executable and lives in
        // a world-readable directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    func openInDefaultHandler(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openSystemSetting(_ setting: SystemSetting) {
        let pane: String
        switch setting {
        case .automation: pane = "com.apple.preference.security?Privacy_Accessibility"
        case .microphone: pane = "com.apple.preference.security?Privacy_Microphone"
        case .notifications: pane = "com.apple.Notifications-Settings.extension"
        case .screenRecording: pane = "com.apple.preference.security?Privacy_ScreenCapture"
        }
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Adapts CoreAudio's numeric device ids to the string ids the protocol uses.
///
/// The conversion is the point. `AudioDeviceID` is a `UInt32` that means
/// something only to CoreAudio, and it had leaked as far as a SwiftUI `Picker`
/// tag. Windows identifies endpoints by string, so the protocol uses strings and
/// this is where the translation lives.
struct MacAudioDevices: AudioDevices {
    var inputs: [AudioDevice] {
        AudioHardware.inputs.map { AudioDevice(id: String($0.id), name: $0.name) }
    }

    var defaultInputID: String { String(AudioHardware.defaultInput) }

    func setDefaultInput(_ id: String) -> Bool {
        guard let device = AudioDeviceID(id) else { return false }
        return AudioHardware.setInput(device)
    }
}

/// Reads the focused window's title to guess that a call is on screen. Titles
/// are inspected and discarded — nothing here persists them.
@MainActor struct MacFocusedWindowInspector: FocusedWindowInspector {
    func focusedWindow() -> FocusedWindow? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return nil }
        return FocusedWindow(appID: app.bundleIdentifier ?? "",
                             appName: app.localizedName ?? "",
                             title: title)
    }
}

/// The microphone, behind `MicrophoneRecorder`.
///
/// The format is Softspoke's choice rather than the caller's: 48 kHz mono
/// 16-bit linear PCM is what whisper.cpp wants, and letting a caller pick would
/// only invite a mismatch further down the pipeline.
@MainActor final class MacMicrophoneRecorder: MicrophoneRecorder {
    private var recorder: AVAudioRecorder?

    func start(writingTo url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let audio = try AVAudioRecorder(url: url, settings: settings)
        audio.isMeteringEnabled = true
        guard audio.record() else { throw flowError("Could not start the microphone.") }
        recorder = audio
    }

    /// Reads the duration before stopping: `AVAudioRecorder.currentTime` drops
    /// to zero once the recorder stops, and the caller needs the length for the
    /// library entry.
    func stop() -> Double? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        return duration
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    var elapsed: Double { recorder?.currentTime ?? 0 }

    /// Converts CoreAudio's decibel reading to 0...1 so callers never see
    /// decibels. -48 dB is treated as silence, which matches what the waveform
    /// and the voice-activity threshold were tuned against.
    func currentLevel() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return max(0, min(1, (recorder.averagePower(forChannel: 0) + 48) / 48))
    }
}
