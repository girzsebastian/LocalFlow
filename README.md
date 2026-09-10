# LocalFlow

### A free, local Wispr Flow alternative for macOS

LocalFlow turns your voice into text in any Mac app. Hold a shortcut, speak, release, and the transcript is inserted where your cursor is. It also records meetings, separates your microphone from computer audio, creates summaries, and lets you chat with the saved discussion.

There is no transcription subscription and no account required. Speech recognition runs locally with Whisper on Apple Silicon. Claude is optional and is used only for the writing and meeting features you choose to run.

[![Download](https://img.shields.io/github/v/release/girzsebastian/LocalFlow?label=download&color=0f766e)](https://github.com/girzsebastian/LocalFlow/releases/latest) [![CI](https://github.com/girzsebastian/LocalFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/girzsebastian/LocalFlow/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![macOS](https://img.shields.io/badge/macOS-26%2B-111827?logo=apple)](https://www.apple.com/macos/) [![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](https://www.swift.org/) [![Whisper](https://img.shields.io/badge/speech-Whisper.cpp-6b46c1)](https://github.com/ggerganov/whisper.cpp) [![Local first](https://img.shields.io/badge/data-local--first-0f766e)](#privacy) [![Stars](https://img.shields.io/github/stars/girzsebastian/LocalFlow?style=flat&color=eab308)](https://github.com/girzsebastian/LocalFlow/stargazers)

**[⬇ Download for Apple Silicon](https://github.com/girzsebastian/LocalFlow/releases/latest)** · [Build from source](#build-from-source) · [How it works](#how-it-works) · [Contributing](CONTRIBUTING.md)

<!--
  DEMO SLOT — the single highest-impact thing left in this README.
  Record ~15s: cursor in a text field, hold the shortcut, speak, release, text appears.
  Save it to docs/media/demo.gif and replace this comment with:
  ![LocalFlow dictating into a text field](docs/media/demo.gif)
-->

## Why LocalFlow exists

Wispr Flow made system-wide voice typing feel natural, but a subscription is not a good fit for everyone and some workflows need local audio. LocalFlow is an open project built around the same useful idea: a small floating control, a global push-to-talk shortcut, automatic paste into the focused app, personal vocabulary, and a meeting workspace.

It is designed for people searching for a **Wispr Flow alternative**, **WisprFlow alternative for Mac**, **offline voice typing**, or a **private local dictation app**.

## What it does

### Dictation

- Hold a configurable keyboard or mouse shortcut to speak; release to finish.
- Double-tap the shortcut for hands-free mode, then press it once to stop.
- After a short pause, completed phrases are transcribed in the background while you continue speaking. Stop only waits for the unprocessed tail.
- Inserts text into the active field, with clipboard fallback when macOS Accessibility insertion is unavailable.
- Mutes Mac output while dictating and restores the previous output state afterward.
- English, Romanian, or multilingual English + Romanian mode.
- Personal dictionary, reusable snippets, styles, transforms, scratchpad, and correction suggestions.
- Optional Claude cleanup before paste: say "send it by Tuesday, oh no, sorry, by Thursday" and the pasted text reads "Send it by Thursday." Fillers and spoken self-corrections are resolved, the literal transcript is kept in the library, and dictation falls back to the raw text if Claude is unavailable. Off by default; enable it under **Settings → Claude**.

### Notetaker

- Record your microphone and, with permission, computer audio from Zoom, Google Meet, or another call.
- See a live conversation with **You** and **Meeting participants** source labels.
- Ask Claude for a summary, decisions, action items, or answers grounded in the captured meeting.
- Keep audio, transcript, meeting segments, summaries, and chat history in the local library.

### A Wispr Flow-style workspace

The app includes a floating widget, language control, dictionary, snippets, styles, transforms, scratchpad, insights, notifications, calendar reminders, and settings for shortcuts, audio, privacy, and Notetaker behavior.

## LocalFlow compared with Wispr Flow

| Capability | LocalFlow | Wispr Flow |
| --- | --- | --- |
| System-wide dictation | Yes | Yes |
| Push-to-talk and toggle modes | Yes | Yes |
| Automatic paste at the cursor | Yes | Yes |
| Background phrase transcription | Yes | Yes |
| English + Romanian multilingual mode | Yes | Yes |
| Notetaker with meeting audio | Yes | Yes |
| Dictionary, snippets, styles, transforms | Yes | Yes |
| Local Whisper transcription | Yes | Service-dependent |
| Transcription subscription | No | Plan-dependent |
| Claude-powered summaries and meeting chat | Optional local Claude CLI | Service-dependent |
| Team accounts and cloud sharing | Not yet | Yes |

## How it works

    Global shortcut
          ↓
    Floating widget → CAF microphone recording → pause detector
                                      ↓
              compact English/Romanian detector
                                      ↓
                         Whisper large-v3-turbo
                                      ↓
                    dictionary and snippets → paste
                              ↓ (optional, off by default)
                Claude cleanup: fillers and "oh no, sorry, I mean…" resolved

Notetaker stores local audio and transcript segments. Claude is an optional step for dictation cleanup, requested summaries, transforms, and meeting questions.

## Install on macOS

The easiest option is the latest Apple Silicon build:

    Download LocalFlow-macOS-Apple-Silicon.dmg from the latest release
    Open it and drag LocalFlow onto the Applications shortcut
    Open /Applications/LocalFlow.app

Install it into `/Applications` rather than running it from `~/Downloads` — macOS ties the Accessibility grant to where the app lives, so an app left in the Downloads folder loses its shortcut permission on the next update. A `.zip` of the same build is attached to each release for anyone scripting the install.

The release is an ad-hoc development build, so macOS may ask you to confirm it under **System Settings → Privacy & Security → Open Anyway**. It does not include the speech models; download those once with the script below. Intel Macs should build from source.

### Build from source

### 1. Install prerequisites

    xcode-select --install
    brew install ffmpeg whisper-cpp

The build scripts currently expect Apple Silicon Homebrew at **/opt/homebrew/bin**.

### 2. Download the speech models

    git clone https://github.com/girzsebastian/LocalFlow.git
    cd LocalFlow
    ./scripts/download-models.sh

The script downloads the quantized Whisper models from the [whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp), verifies their SHA-256 checksums, and stores them under **~/Library/Application Support/LocalFlow/Models/**.

### 3. Build and install

    ./build.sh
    ditto build/LocalFlow.app /Applications/LocalFlow.app
    open /Applications/LocalFlow.app

On first launch, allow Microphone access. Add LocalFlow under **System Settings → Privacy & Security → Accessibility** so the global shortcut and automatic paste can work. The first launch may show an unidentified-developer warning because development builds are ad-hoc signed; use **Open Anyway** in Privacy & Security.

### 4. Use it

1. Choose a shortcut in Settings, or select Mouse 4 / Mouse 5.
2. Put the cursor in any text field.
3. Hold the shortcut, speak, and release.
4. For long thoughts, pause naturally. Completed phrases will be ready before you stop.

## Privacy

Speech audio is processed on the Mac by Whisper.cpp. LocalFlow does not require a transcription account, does not send microphone audio to a transcription API, and does not include telemetry. The local Whisper server binds to **127.0.0.1** only.

Claude is an optional separate path. It uses the existing **claude** CLI login for requested summaries, transforms, and meeting questions. Read the prompt and choose the Claude action before sending transcript text to it. If you turn on **Clean up dictation with Claude before pasting**, every dictation transcript is sent to Claude before it is pasted; leave it off if you dictate content that must not leave your Mac.

## Architecture

| Area | Implementation |
| --- | --- |
| App and widget | SwiftUI + AppKit |
| Global shortcuts | Carbon hotkeys and AppKit mouse monitoring |
| Audio capture | AVAudioRecorder, linear PCM CAF |
| System audio | ScreenCaptureKit |
| Speech recognition | whisper.cpp **whisper-server** with Metal |
| Language routing | Compact Whisper detect-only server, English/Romanian constrained |
| Text insertion | Accessibility API with clipboard paste fallback |
| Meeting intelligence | Claude CLI, only when requested or enabled |
| Storage | Local JSON archive and audio files |

## Project layout

The code is split into a portable core and a macOS platform layer. **`Sources/Core` compiles with nothing but Foundation** — CI builds it on a Windows runner so that stays true.

    Sources/Core/Models.swift                 Entry, Preferences, Archive, text expansion
    Sources/Core/PlatformCapabilities.swift   The protocols an OS layer must implement
    Sources/Core/SpeechRouting.swift          Language detection and silence chunking
    Sources/Core/WhisperServer.swift          Localhost Whisper model process
    Sources/Core/AppPaths.swift               Every filesystem location, in one place

    Sources/Platform/macOS/PasteDestination.swift   Focused-app text insertion
    Sources/Platform/macOS/MeetingAudio.swift       ScreenCaptureKit system audio
    Sources/Platform/macOS/SystemAudio.swift        CoreAudio devices and output mute

    Sources/App.swift                         App state and recording lifecycle
    Sources/FloatingControl.swift             Floating widget and waveform
    Sources/WhisperTranscription.swift        Audio preparation and transcription
    Sources/LiveNotetaker.swift               Live transcript, summary, and meeting chat

    Tests/Core/CoreTests.swift                Portable suite — runs on every platform
    Package.swift                             Builds and tests the core with SwiftPM
    build.sh                                  Native macOS app build and ad-hoc signing

Windows support is [issue #7](https://github.com/girzsebastian/LocalFlow/issues/7). The core and the protocol contract are in place; the Windows implementation is open.

## Performance

On an Apple M2 Pro test machine:

- A bilingual English/Romanian sample completed in 4.93 seconds and preserved both languages.
- A 118-second real dictation completed from scratch in 19.69 seconds.
- Two phrase-level background requests completed in 4.65 seconds.

The first model warm-up is slower. Actual timing depends on the Mac, recording length, pauses, and whether the background queue has already processed the phrases.

## Troubleshooting

**The shortcut does nothing**

Confirm LocalFlow is enabled under Accessibility, then restart the app. Secure Input fields such as password prompts can block global keyboard monitoring.

**The transcript is copied but not inserted**

The text remains in the clipboard. Re-enable Accessibility and try again; the widget explains the current failure without opening the main window.

**The app says the model is missing**

Run **./scripts/download-models.sh** again and verify that both model files are under **~/Library/Application Support/LocalFlow/Models/**.

**The first dictation is slow**

The local Whisper processes are loading their models. Later phrases reuse the warm processes.

## Development

    ./build.sh        # builds and ad-hoc signs build/LocalFlow.app
    swift test        # test suite: no models, no microphone, no network

Run `swift test` before opening a pull request; CI runs it on macOS and again on Windows. See [VALIDATION.md](VALIDATION.md) for the tested flows and the manual checks that still need a human, and [CHANGELOG.md](CHANGELOG.md) for what shipped in each release.

## Status

LocalFlow is an active personal project. The core dictation and Notetaker flows are usable; automatic call-end detection, cloud team accounts, connector management, screen-share hiding, and signed distribution are still planned.

## Contributing

Contributions are welcome and the project is deliberately easy to get running: clone, `./scripts/download-models.sh`, `./build.sh`. The offline test suite is one command and needs no models, microphone, or network:

    swift test

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the setup, the code style, and the one rule that is not negotiable — **speech audio never leaves the machine**. Issues tagged [good first issue](https://github.com/girzsebastian/LocalFlow/labels/good%20first%20issue) are scoped small on purpose; Intel Mac support, extra languages, and a Homebrew cask are all open.

First-time contributors sign a short [CLA](CLA.md) — one comment, once, and you keep the copyright to your work. Please also read the [Code of Conduct](CODE_OF_CONDUCT.md). For security problems, do not open a public issue — see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Use it, fork it, ship it. If LocalFlow saves you a subscription, a star is a fair trade.
