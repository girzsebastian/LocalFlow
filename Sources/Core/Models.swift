import Foundation

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var kind: String
    var date = Date()
    var transcript = ""
    /// The literal Whisper output when Claude cleanup rewrote `transcript`.
    var rawTranscript: String? = nil
    var insights = ""
    var audio: String? = nil
    var systemAudio: String? = nil
    var duration: Double? = nil
    var applicationName: String? = nil
    var meetingSegments: [MeetingSegment]? = nil
    var meetingChats: [NoteExchange]? = nil
}
struct MeetingSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var offset: Double
    var speaker: String
    var text: String
}
struct Preferences: Codable {
    var locale = "auto"
    var multilingualConfigured: Bool? = nil
    var voiceProfile: String? = nil
    var voiceProfileDate: Date? = nil
    var noteChats: [NoteExchange]? = nil
    var muteWhileDictating: Bool? = nil
    var autoHideWidget: Bool? = nil
    var meetingPrompts: Bool? = nil
    var recommendationNotifications: Bool? = nil
    var suggestCorrections: Bool? = nil
    var showWidgetAlways: Bool? = nil
    var showDock: Bool? = nil
    var sounds: Bool? = nil
    var openNotepad: Bool? = nil
    var maxNoteMinutes: Int? = nil
    var scratchpadBehavior: String? = nil
    var calendarEnabled: Bool? = nil
    var meetingReminderSeconds: Int? = nil
    var showNextMeeting: Bool? = nil
    var notetakerConfigured: Bool? = nil
    var snippets = ""
    var dictionary = ""
    var style = "Keep my wording"
    var scratchpad = ""
    var autoInsights = false
    /// Opt-in: send each dictation to Claude before pasting so fillers and spoken
    /// self-corrections ("oh no, sorry, I mean…") are resolved.
    var cleanDictation: Bool? = nil
    var autoPaste = true
    var pasteConfigured: Bool? = nil
    /// macOS Carbon keycode and modifier bitmask. Meaningless on other
    /// platforms; kept so an existing install keeps working and so downgrading
    /// does not lose the shortcut. `shortcutChord` is the portable record.
    var shortcutCode: UInt32? = nil
    var shortcutModifiers: UInt32? = nil
    /// Platform-neutral form of the same shortcut. Written alongside the Carbon
    /// fields, and back-filled from `shortcutLabel` for older archives.
    var shortcutChord: KeyChord? = nil
    var shortcutMouse: Int? = nil
    var shortcutLabel: String? = nil
    var captureSystem = false
    var transformer = "Rewrite this clearly and concisely, preserving meaning and language."
}
struct NoteExchange: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var question: String
    var answer: String
}
struct Archive: Codable { var entries: [Entry]; var preferences: Preferences }
func flowError(_ message: String) -> NSError { NSError(domain: "Softspoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

/// Optional Claude pass that turns a literal dictation into the message the
/// speaker meant: fillers removed, spoken self-corrections applied.
enum DictationCleanup {
    static let instruction = [
        "Rewrite this dictated text as the final message the speaker intended.",
        "Remove filler words and false starts.",
        "Apply the speaker's spoken self-corrections: when they say things like \"oh no\", \"sorry\", \"I mean\", \"no wait\", \"scratch that\", \"actually\" or \"not X, Y\", keep only the replacement and drop what it replaced.",
        "Keep the speaker's meaning, tone, wording and language. Fix punctuation and capitalization.",
        "Do not add greetings, sign-offs, explanations or anything the speaker did not say.",
        "Return only the cleaned text.",
    ].joined(separator: " ")

    /// Seconds to wait for Claude before pasting the raw transcript instead.
    static let timeout: TimeInterval = 45

    /// Decides whether a Claude result may replace the dictation. Rejects empty
    /// output, output that grew a lot (a sign the model answered the transcript
    /// instead of rewriting it), and assistant-style prefaces.
    static func accept(raw: String, cleaned: String) -> String? {
        let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        guard result.count <= max(raw.count + 40, Int(Double(raw.count) * 1.3)) else { return nil }
        let lower = result.lowercased()
        for preface in ["here is", "here's", "i can't", "i cannot", "i'm sorry, but", "as an ai"] where lower.hasPrefix(preface) { return nil }
        return result
    }
}
func expand(_ text: String, rules: String) -> String {
    rules.split(separator: "\n").reduce(text) { result, line in
        let parts = line.components(separatedBy: "=>")
        guard parts.count == 2 else { return result }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return result }
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: key) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return result }
        return regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: parts[1].trimmingCharacters(in: .whitespaces)))
    }
}

