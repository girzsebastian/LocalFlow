# Changelog

All notable changes to LocalFlow are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **You will be asked to allow LocalFlow again, once.** The bundle identifier moved from `com.oryntech.localflow` to `io.github.girzsebastian.localflow`, dropping a company name that was never part of this project. macOS keys permissions on that identifier, so it treats the next build as a new application: grant Accessibility and Microphone one more time under **System Settings → Privacy & Security**, and remove the old LocalFlow entry from the Accessibility list while you are there.

  Your library is not affected. Recordings, transcripts and preferences live under `~/Library/Application Support/LocalFlow/`, a path built from the app's name rather than its identifier.

- The Snippets example no longer carries a personal signature.


## [0.4.0] — 2026-09-10

Mostly internal, with one change users will notice.

### Added

- **Releases now ship a `.dmg`.** Open it and drag LocalFlow onto the Applications shortcut. Installing into `/Applications` rather than running from `~/Downloads` matters: macOS ties the Accessibility grant to where the app lives, so an app left in Downloads loses its shortcut permission on the next update. The `.zip` is still attached for anyone scripting the install.

### Fixed

- **Intel Macs.** `ffmpeg`, `whisper-server` and `whisper-cli` were hardcoded to `/opt/homebrew/bin`, which is Apple Silicon Homebrew. They are now located by searching, so `/usr/local/bin` works too. A missing tool now names the `brew install` to run instead of failing on a bare path.
- A child process that ignored a polite stop was killed with a POSIX signal, which does not exist off Unix.

### Changed

- The code is split into `Sources/Core`, which compiles with nothing but Foundation, and `Sources/Platform/macOS`. CI builds the core on a Windows runner so the boundary stays real. Nothing about the macOS app's behaviour changes; this is groundwork for [#7](https://github.com/girzsebastian/LocalFlow/issues/7).
- Your shortcut is now also recorded in a portable form. LocalFlow used to persist raw Carbon keycodes, which mean nothing on another platform. The new form is written alongside the old one and filled in from the shortcut you already have, so nothing needs re-recording.
- One test suite instead of two, and it runs on every platform. Coverage of the portable core went from 21% to 66%.
- CodeQL analysis and Dependabot for GitHub Actions.


Nothing yet.

## [0.3.0] — 2026-09-08

### Added

- Optional **Clean up dictation with Claude before pasting** (Settings → Claude,
  off by default). After local transcription, dictionary and snippet expansion,
  the transcript is sent to Claude with a fixed cleanup instruction that removes
  fillers and applies spoken self-corrections such as "by Tuesday, oh no, sorry,
  by Thursday" or "cc John, I mean Jane". The cleaned text is what gets pasted
  and copied. The literal Whisper transcript is kept on the library entry under
  **Before Claude cleanup**, with **Restore literal** to undo.
- The cleanup step has a 45-second timeout and an output guard. If Claude is
  slow, signed out, refuses, or returns something that is not a rewrite, the raw
  dictation is pasted and the widget says so. Dictation never blocks on Claude.
- Offline tests for the cleanup guard and preference defaults, plus a
  `cleanup` smoke test that runs the real Claude CLI.

## [0.2.0] — 2026-09-08

First public release. Apple Silicon, macOS 26 or newer.

### Dictation

- Global push-to-talk shortcut, keyboard or Mouse 4 / Mouse 5, with hold-and-release
  and double-tap hands-free modes.
- Background phrase transcription: completed phrases are transcribed while you keep
  speaking, so stopping only waits for the unprocessed tail.
- Text insertion into the focused app through the Accessibility API, with a
  clipboard fallback when insertion is unavailable.
- Mac output is muted while dictating and the previous output state is restored.
- English, Romanian, and multilingual English + Romanian modes, routed by a
  compact detect-only Whisper server.
- Personal dictionary, snippets, styles, transforms, scratchpad, and correction
  suggestions learned from edits you make to dictated text.

### Notetaker

- Microphone recording plus, with permission, computer audio from Zoom, Google
  Meet, or another call via ScreenCaptureKit.
- Live transcript with **You** and **Meeting participants** source labels.
- Optional Claude summaries, decisions, action items, and questions answered
  against the captured meeting.
- Local library of audio, transcripts, segments, summaries, and chat history.

### App

- Floating widget that retracts to an edge handle when idle and expands on
  pointer proximity.
- Settings split into General, System, Notetaker, Notifications, Claude, and
  Data & Privacy.
- Local notifications and optional calendar reminders that can start a note.
- Heuristic meeting-window matching that suggests a note when a call window is
  focused. No window titles are persisted.
- Usage insights that exclude notes and do not fabricate unmeasured durations.

### Privacy

- Speech recognition runs locally through `whisper.cpp` with Metal. The local
  Whisper server binds to `127.0.0.1` only.
- No transcription account, no telemetry.
- Claude is optional, uses the existing `claude` CLI login, and only runs on
  actions you choose.

### Known limitations

- Ad-hoc signed, not notarized. macOS shows an unidentified-developer warning on
  first launch; use **Open Anyway** in Privacy & Security.
- Apple Silicon only. The build scripts assume Homebrew at `/opt/homebrew/bin`.
- Automatic call-end detection, team accounts, connector management, screen-share
  hiding, and signed distribution are not implemented.

[Unreleased]: https://github.com/girzsebastian/LocalFlow/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/girzsebastian/LocalFlow/releases/tag/v0.4.0
[0.3.0]: https://github.com/girzsebastian/LocalFlow/releases/tag/v0.3.0
[0.2.0]: https://github.com/girzsebastian/LocalFlow/releases/tag/v0.2.0
