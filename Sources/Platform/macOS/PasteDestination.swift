import AppKit

@MainActor struct PasteDestination {
    let application: NSRunningApplication
    let element: AXUIElement?
    static func capture(application: NSRunningApplication?) -> PasteDestination? {
        guard let application, application.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        var focused: CFTypeRef?
        if AXIsProcessTrusted() {
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused)
        }
        let element = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        return PasteDestination(application: application, element: element)
    }
    func insert(_ text: String) async throws -> String {
        guard AXIsProcessTrusted() else { throw flowError("Transcript copied. Enable Softspoke in System Settings → Privacy & Security → Accessibility, then try again.") }
        guard !application.isTerminated else { throw flowError("The original app closed. Your transcript is copied; paste it wherever you need.") }
        application.activate(options: [.activateAllWindows])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { throw flowError("Could not focus the original app. Your transcript is copied; press Command V there.") }
        if let element {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
                if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return "Dictation inserted at your cursor" }
            }
        }
        // Wait for physical shortcut modifiers to lift before sending Command V.
        for _ in 0..<30 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { throw flowError("Focus changed before paste. Your transcript is copied.") }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw flowError("Could not send paste. Your transcript is copied.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(30))
        up.post(tap: .cghidEventTap)
        return "Paste sent to \(application.localizedName ?? "your app")"
    }

    func correctionBaseline(for inserted: String) async -> (text: String, range: NSRange)? {
        guard let element else { return nil }
        try? await Task.sleep(for: .milliseconds(180))
        guard let text = textValue() else { return nil }
        let ns = text as NSString
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedValue) == .success,
           let selectedValue, CFGetTypeID(selectedValue) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(selectedValue as! AXValue, .cfRange, &selected) {
                let length = (inserted as NSString).length
                let range = NSRange(location: selected.location - length, length: length)
                if range.location >= 0, NSMaxRange(range) <= ns.length, ns.substring(with: range) == inserted {
                    return (text, range)
                }
            }
        }
        let range = ns.range(of: inserted, options: .backwards)
        return range.location == NSNotFound ? nil : (text, range)
    }

    func textValue() -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
