import XCTest
@testable import SoftspokeCore

/// Tests for the portable half of Softspoke. These run on every platform Swift
/// supports, including Windows, which is the point: they are how a Windows
/// build is verified before a Windows UI exists.
///
/// This is the only test suite. There was a second, macOS-only one; every
/// assertion in it tested portable logic, so it could never fail on the platform
/// it was meant to guard. See issue #10.
final class CoreTests: XCTestCase {

    // MARK: Text expansion

    func testExpansionReplacesWholeWordsOnly() {
        XCTAssertEqual(expand("My email is ready", rules: "my email => hello@example.com"),
                       "hello@example.com is ready")
        XCTAssertEqual(expand("the cat and catalog", rules: "cat => dog"),
                       "the dog and catalog",
                       "a rule must not fire inside a longer word")
        XCTAssertEqual(expand("cost", rules: "cost => $5"), "$5",
                       "a replacement containing $ must not be read as a capture group")
        XCTAssertEqual(expand("keep me", rules: "invalid\n => bad"), "keep me",
                       "a malformed rule is skipped rather than corrupting the text")
    }

    // MARK: Dictation cleanup guard

    func testCleanupAcceptsAGenuineRewrite() {
        let raw = "send it by Tuesday, oh no, sorry, by Thursday. I want to, um, I want to review it first"
        XCTAssertEqual(DictationCleanup.accept(raw: raw, cleaned: "Send it by Thursday. I want to review it first."),
                       "Send it by Thursday. I want to review it first.")
        XCTAssertEqual(DictationCleanup.accept(raw: raw, cleaned: "  Send it by Thursday.\n"),
                       "Send it by Thursday.",
                       "surrounding whitespace is trimmed rather than pasted")
        XCTAssertNil(DictationCleanup.accept(raw: raw, cleaned: ""))
    }

    func testCleanupIsOffUntilTheUserAsksForIt() {
        XCTAssertNil(Preferences().cleanDictation,
                     "sending dictation to Claude must stay opt-in")
    }

    func testCleanupRejectsAnswersInsteadOfRewrites() {
        let raw = "um so I think we should uh ship on Thursday no wait Friday"
        XCTAssertNil(DictationCleanup.accept(raw: raw, cleaned: "   "))
        XCTAssertNil(DictationCleanup.accept(raw: raw, cleaned: "Here is the cleaned text: ship Friday."))
        XCTAssertNil(DictationCleanup.accept(raw: raw, cleaned: "I can't help with that request."))
        XCTAssertNil(DictationCleanup.accept(raw: raw, cleaned: String(repeating: "Friday works. ", count: 20)),
                     "output that grew this much means the model answered the transcript")
        XCTAssertEqual(DictationCleanup.accept(raw: "hi", cleaned: "Hi, how are you doing today?"),
                       "Hi, how are you doing today?",
                       "short input may legitimately grow")
    }

    // MARK: Portable shortcut

    func testChordParsesFromDisplayLabel() {
        XCTAssertEqual(KeyChord(displayLabel: "⌃⇧Space"),
                       KeyChord(key: "Space", control: true, shift: true))
        XCTAssertEqual(KeyChord(displayLabel: "⌃⌥⇧⌘M"),
                       KeyChord(key: "M", control: true, alt: true, shift: true, command: true))
        XCTAssertEqual(KeyChord(displayLabel: "⌥F13")?.key, "F13")
    }

    func testChordRejectsLabelsThatCannotTravel() {
        XCTAssertNil(KeyChord(displayLabel: "M"), "a bare key is not a global shortcut")
        XCTAssertNil(KeyChord(displayLabel: "⌃Key 42"), "\"Key 42\" is a raw macOS keycode")
        XCTAssertNil(KeyChord(displayLabel: "⌃⇧"), "modifiers with no key")
    }

    // MARK: Archive compatibility

    func testArchiveWrittenBeforeKeyChordStillDecodes() throws {
        let old = #"{"locale":"auto","snippets":"","dictionary":"","style":"x","scratchpad":"","autoInsights":false,"autoPaste":true,"captureSystem":false,"transformer":"x","shortcutLabel":"⌃⇧Space"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertNil(decoded.shortcutChord)
        XCTAssertEqual(decoded.shortcutLabel, "⌃⇧Space")
        XCTAssertNil(decoded.cleanDictation, "an absent opt-in must not default to on")
    }

    func testEntryKeepsTheLiteralTranscriptThroughARoundTrip() throws {
        var entry = Entry(title: "Test", kind: "Dictation", transcript: "Send it by Thursday.")
        entry.rawTranscript = "um send it by uh Thursday"
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.rawTranscript, "um send it by uh Thursday")
        XCTAssertEqual(decoded.transcript, "Send it by Thursday.")
    }

    // MARK: Meeting detection

    /// Note for the Windows port: this matcher compiles anywhere, but the data
    /// it matches on is macOS bundle identifiers. Windows reports process names
    /// ("Zoom.exe", "chrome.exe"), so the identifier set needs a platform-aware
    /// table before the Notetaker's meeting detection works there. See issue #7.
    func testMeetingMatcherIgnoresAppHomeScreens() {
        XCTAssertTrue(MeetingWindowMatcher.matches(bundle: "us.zoom.xos", title: "Zoom Meeting"))
        XCTAssertFalse(MeetingWindowMatcher.matches(bundle: "us.zoom.xos", title: "Zoom Workplace"),
                       "the app's own home window is not a call")
        XCTAssertTrue(MeetingWindowMatcher.matches(bundle: "com.google.Chrome", title: "Meet – abc-defg-hij"))
        XCTAssertFalse(MeetingWindowMatcher.matches(bundle: "com.google.Chrome", title: "Google Meet"),
                       "the Meet landing page is not a call")
        XCTAssertFalse(MeetingWindowMatcher.matches(bundle: "com.apple.TextEdit", title: "Meet – abc-defg-hij"),
                       "a matching title in an unrelated app must not count")
    }

    // MARK: Speech segmentation

    func testChunksStayWithinTheMaximumLength() {
        let chunks = SpeechSegmentation.chunks(duration: 60, silences: [(20, 21), (40, 41)], maximum: 24)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.end - chunk.start, 24.0 + .ulpOfOne,
                                     "a chunk longer than the maximum would blow the model's context")
            XCTAssertLessThan(chunk.start, chunk.end)
        }
        XCTAssertEqual(chunks.first?.start, 0, "the first chunk starts at the beginning of the recording")
        XCTAssertEqual(chunks.last?.end, 60, "the last chunk reaches the end, so no speech is dropped")
    }

    func testPausesTooShortToBeSentenceBreaksAreIgnored() {
        // A 0.2s gap is a breath, not a boundary. Splitting there produced
        // one-second clips whose language detection jumped to other scripts.
        let chunks = SpeechSegmentation.chunks(duration: 30, silences: [(10, 10.2)], maximum: 24)
        XCTAssertEqual(chunks.count, 2, "30s with no usable boundary still splits only to respect the maximum")
        XCTAssertEqual(chunks.first?.end, 24)
    }

    func testSilenceSplitsAtTheMiddleOfThePause() {
        XCTAssertEqual(SpeechSegmentation.chunks(duration: 12, silences: [(5, 6)]),
                       [SpeechChunk(start: 0, end: 5.5), SpeechChunk(start: 5.5, end: 12)])
        XCTAssertEqual(SpeechSegmentation.chunks(duration: 8, silences: [(1, 1.5)]).count, 1,
                       "a boundary too close to the start would leave a clip too short to detect")
    }

    // MARK: The shortcut state machine
    //
    // Hold-to-talk, double-tap to latch, and the release timer. This is the
    // heart of the dictation trigger and it is pure logic, so a Windows build
    // must not be able to break it without a test noticing.

    func testHoldAndReleaseIgnoresKeyRepeat() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(at: 0), [.start])
        XCTAssertTrue(gesture.down(at: 0.1).isEmpty, "auto-repeat must not restart the recording")
        XCTAssertEqual(gesture.up(at: 1), [.stop])
        XCTAssertTrue(gesture.up(at: 1.1).isEmpty, "a second release must not stop twice")
    }

    func testDoubleTapLatchesAndTheNextPressStops() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(at: 2), [.start])
        XCTAssertEqual(gesture.up(at: 2.1), [.scheduleRelease],
                       "a quick release might still become a double tap, so stopping waits")
        XCTAssertEqual(gesture.down(at: 2.25), [.cancelRelease, .latch])
        XCTAssertTrue(gesture.up(at: 2.3).isEmpty, "releasing a latched recording keeps it running")
        XCTAssertTrue(gesture.releaseExpired().isEmpty, "the cancelled timer must not fire")
        XCTAssertEqual(gesture.down(at: 5), [.stop])
    }

    func testASingleTapStopsWhenTheDoubleTapWindowExpires() {
        var gesture = ShortcutGesture()
        _ = gesture.down(at: 6)
        _ = gesture.up(at: 6.1)
        XCTAssertEqual(gesture.releaseExpired(), [.stop])
    }

    // MARK: Language routing

    func testDetectionsAreParsedFromTheWhisperLog() {
        let parsed = LanguageRouting.detections(in: """
            auto-detected language: ro (p = 0.616654)
            auto-detected language: en (p = 0.91)
            """)
        XCTAssertEqual(parsed, [LanguageDetection(language: "ro", confidence: 0.616654),
                                LanguageDetection(language: "en", confidence: 0.91)])
    }

    func testLowConfidenceRomanianWithLatinTextRetriesInEnglish() {
        let parsed = LanguageRouting.detections(in: "auto-detected language: ro (p = 0.616654)")
        XCTAssertTrue(LanguageRouting.needsEnglishRetry(parsed[0], text: "platformă pe care"))
        XCTAssertFalse(LanguageRouting.needsEnglishRetry(LanguageDetection(language: "ro", confidence: 0.99),
                                                         text: "Bună ziua"),
                       "a confident detection is trusted")
        XCTAssertTrue(LanguageRouting.needsEnglishRetry(nil, text: "hello 대에르"),
                      "an unsupported script means the model wandered off")
    }

    // MARK: Corrections learned from edits

    func testEditedWordsBecomeDictionarySuggestionsButAppendedTextDoesNot() {
        XCTAssertEqual(
            CorrectionWordDiff.suggestion(baseline: "Send this to chersid today",
                                          edited: "Send this to Kerrsid today",
                                          insertedRange: NSRange(location: 0, length: 26)),
            CorrectionSuggestion(original: "chersid", corrected: "Kerrsid"))
        XCTAssertNil(
            CorrectionWordDiff.suggestion(baseline: "hello", edited: "hello world",
                                          insertedRange: NSRange(location: 0, length: 5)),
            "continuing to type is not a correction of what was dictated")
    }

    // MARK: Usage

    func testUsageExcludesNotesAndNeverInventsADuration() {
        let summary = UsageSummary(entries: [
            Entry(title: "One", kind: "Dictation", transcript: "one two three four", duration: 2),
            Entry(title: "Note", kind: "Notetaker", transcript: "not counted"),
            Entry(title: "Old", kind: "Dictation", transcript: "five six"),
        ])
        XCTAssertEqual(summary.totalWords, 6, "meeting notes are not dictated words")
        XCTAssertEqual(summary.wordsPerMinute, 120, "only the entry with a measured duration counts")
        XCTAssertNil(UsageSummary(entries: []).wordsPerMinute)
    }

    // MARK: Platform paths
    //
    // These exercise the Windows layout from a Mac. Without that, the Windows
    // branches would only ever be compiled by CI and never actually run by
    // anyone until someone tried the app on Windows.

    private var fakeHome: URL { URL(fileURLWithPath: "/Users/test") }

    func testWindowsDataLivesUnderAppData() {
        // Asserted as a relationship rather than an absolute string: this runs
        // on macOS, where URL(fileURLWithPath:) reads "C:/..." as relative
        // because it has no leading slash. The logic under test is "append
        // Softspoke to %APPDATA%", not how Foundation parses a drive letter.
        let appData = "/fake/AppData/Roaming"
        let root = AppPaths.root(platform: .windows,
                                 environment: ["APPDATA": appData],
                                 home: fakeHome)
        XCTAssertEqual(root.lastPathComponent, "Softspoke")
        XCTAssertEqual(root.deletingLastPathComponent().path, appData)
        XCTAssertFalse(root.path.contains("Library"), "the macOS layout must not leak in")
    }

    func testWindowsFallsBackWhenAppDataIsMissing() {
        // A service or a stripped environment may not set %APPDATA%; guessing
        // the conventional location beats writing to the wrong place.
        let root = AppPaths.root(platform: .windows, environment: [:], home: fakeHome)
        XCTAssertEqual(root.path, "/Users/test/AppData/Roaming/Softspoke")
    }

    func testMacDataStaysWhereItAlwaysWas() {
        let root = AppPaths.root(platform: .apple, environment: ["APPDATA": "ignored"], home: fakeHome)
        XCTAssertEqual(root.path, "/Users/test/Library/Application Support/Softspoke",
                       "%APPDATA% must not leak into the macOS layout and move an existing library")
    }

    func testClaudeIsLookedForWhereEachPlatformInstallsIt() {
        XCTAssertEqual(
            AppPaths.claudeExecutable(platform: .apple, environment: [:], home: fakeHome).path,
            "/Users/test/.local/bin/claude")
        let windows = AppPaths.claudeExecutable(platform: .windows,
                                                environment: ["APPDATA": "/fake/AppData/Roaming"],
                                                home: fakeHome)
        XCTAssertEqual(windows.path, "/fake/AppData/Roaming/npm/claude.cmd",
                       "npm installs the CLI as a .cmd shim, not a bare executable")
    }

    // MARK: Migrating a library from before the rename
    //
    // These use real directories in a temporary location, because the whole
    // point is whether the filesystem operation behaves — a mocked FileManager
    // would prove nothing about the case that matters.

    private func makeSandbox() throws -> URL {
        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent("softspoke-migration-\(UUID())")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        return box
    }

    private func writeLibrary(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("archive.json"), atomically: true, encoding: .utf8)
    }

    func testALibraryFromTheOldNameIsMoved() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = AppPaths.legacyRoot(platform: .apple, environment: [:], home: home)
        try writeLibrary(at: legacy, marker: "fifty-three entries")

        let moved = try AppPaths.migrateLibraryFromLegacyName(platform: .apple, environment: [:], home: home)
        XCTAssertTrue(moved)

        let current = AppPaths.root(platform: .apple, environment: [:], home: home)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("archive.json"), encoding: .utf8),
                       "fifty-three entries",
                       "the library must arrive intact, not merely exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "a move leaves nothing behind; a copy would double an 800MB library")
    }

    func testAnExistingLibraryIsNeverOverwritten() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = AppPaths.legacyRoot(platform: .apple, environment: [:], home: home)
        let current = AppPaths.root(platform: .apple, environment: [:], home: home)
        try writeLibrary(at: legacy, marker: "old")
        try writeLibrary(at: current, marker: "current")

        let moved = try AppPaths.migrateLibraryFromLegacyName(platform: .apple, environment: [:], home: home)
        XCTAssertFalse(moved, "merging two libraries is not something to do silently")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("archive.json"), encoding: .utf8),
                       "current",
                       "the library in use must survive untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "and the old one is left for the user to deal with, not deleted")
    }

    func testMigrationIsAQuietNoOpWithNothingToMove() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(try AppPaths.migrateLibraryFromLegacyName(platform: .apple, environment: [:], home: home),
                       "a fresh install has no legacy directory and must not fail")
    }

    func testMigrationRunsOnlyOnce() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeLibrary(at: AppPaths.legacyRoot(platform: .apple, environment: [:], home: home), marker: "x")

        XCTAssertTrue(try AppPaths.migrateLibraryFromLegacyName(platform: .apple, environment: [:], home: home))
        XCTAssertFalse(try AppPaths.migrateLibraryFromLegacyName(platform: .apple, environment: [:], home: home),
                       "every launch after the first must take the no-op path")
    }

    func testWindowsLibrariesMigrateToo() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let appData = home.appendingPathComponent("Roaming")
        let environment = ["APPDATA": appData.path]
        try writeLibrary(at: AppPaths.legacyRoot(platform: .windows, environment: environment, home: home), marker: "w")

        XCTAssertTrue(try AppPaths.migrateLibraryFromLegacyName(platform: .windows, environment: environment, home: home))
        let current = AppPaths.root(platform: .windows, environment: environment, home: home)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("archive.json"), encoding: .utf8), "w")
    }

    // MARK: Locating external tools

    func testMacSearchesBothHomebrewPrefixes() {
        let directories = Tools.directories(platform: .apple, environment: ["PATH": "/custom/bin"])
        XCTAssertEqual(directories.first, "/opt/homebrew/bin", "Apple Silicon Homebrew stays first")
        XCTAssertTrue(directories.contains("/usr/local/bin"),
                      "Intel Homebrew must be searched too — this is issue #1")
        XCTAssertTrue(directories.contains("/custom/bin"), "a user's own PATH is honoured")
    }

    func testWindowsSplitsPathOnSemicolons() {
        let directories = Tools.directories(
            platform: .windows,
            environment: ["PATH": "C:/tools;C:/Windows/System32"])
        XCTAssertEqual(directories, ["C:/tools", "C:/Windows/System32"],
                       "splitting on ':' would cut every Windows path after the drive letter")
    }

    func testChildProcessPathUsesEachPlatformsSeparator() {
        XCTAssertTrue(Tools.childPath(platform: .windows,
                                             environment: ["PATH": "C:/a;C:/b"]).contains(";"))
        XCTAssertFalse(Tools.childPath(platform: .windows,
                                              environment: ["PATH": "C:/a;C:/b"]).contains(":;"))
        XCTAssertTrue(Tools.childPath(platform: .apple, environment: ["PATH": "/a"]).contains(":"))
    }

    func testWindowsLooksForExecutableExtensions() {
        XCTAssertEqual(Tools.candidateNames(for: "ffmpeg", platform: .windows),
                       ["ffmpeg.exe", "ffmpeg.cmd", "ffmpeg"],
                       ".cmd matters because npm-installed tools are shims, not executables")
        XCTAssertEqual(Tools.candidateNames(for: "ffmpeg", platform: .apple), ["ffmpeg"])
    }

    // MARK: Child processes

    // The commands differ per platform; the behaviour being tested does not.
    private var sleepCommand: (URL, [String]) {
        #if os(Windows)
        (URL(fileURLWithPath: "C:/Windows/System32/cmd.exe"), ["/c", "ping", "-n", "11", "127.0.0.1"])
        #else
        (URL(fileURLWithPath: "/bin/sleep"), ["10"])
        #endif
    }

    private var echoCommand: (URL, [String]) {
        #if os(Windows)
        (URL(fileURLWithPath: "C:/Windows/System32/cmd.exe"), ["/c", "echo", "process works"])
        #else
        (URL(fileURLWithPath: "/bin/echo"), ["process works"])
        #endif
    }

    func testTimeoutReturnsWithoutWaitingForTheChild() async throws {
        let started = Date()
        let (tool, arguments) = sleepCommand
        do {
            _ = try await LocalProcess().run(tool, arguments: arguments, timeout: 0.2)
            XCTFail("the timeout did not fire")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                              "the caller must not be held hostage by a child that ignores SIGTERM")
        }
    }

    func testCancellationPropagatesAndLaterRunsStillWork() async throws {
        let (tool, arguments) = sleepCommand
        let child = Task { try await LocalProcess().run(tool, arguments: arguments, timeout: 30) }
        try await Task.sleep(for: .milliseconds(100))
        child.cancel()
        do {
            _ = try await child.value
            XCTFail("cancellation did not fire")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let (echo, echoArguments) = echoCommand
        let output = try await LocalProcess().run(echo, arguments: echoArguments, timeout: 5)
        XCTAssertTrue(output.contains("process works"), "a cancelled run must not poison the next one")
    }
}
