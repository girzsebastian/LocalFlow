# Contributing to LocalFlow

Thanks for taking the time. LocalFlow is a small, dependency-light macOS app, and
it is deliberately easy to get running — you should be building and testing it
within a few minutes.

## Ground rules

- **Local-first is not negotiable.** Speech audio must never leave the machine.
  A change that sends microphone audio, transcripts, or usage data to a remote
  service without an explicit, user-initiated action will not be merged.
- **No telemetry.** No analytics SDKs, no crash reporters that phone home, no
  "anonymous" pings.
- **No new runtime dependencies without discussion.** The app builds with
  `swiftc` and the system frameworks. If your change needs a package manager,
  open an issue first.
- **Claude is optional.** Anything that requires the `claude` CLI must degrade
  gracefully when it is absent.

## Set up

    xcode-select --install
    brew install ffmpeg whisper-cpp
    git clone https://github.com/girzsebastian/LocalFlow.git
    cd LocalFlow
    ./scripts/download-models.sh   # one time, ~1.5 GB

You need macOS 26 or newer and an Apple Silicon Mac. The build scripts currently
assume Homebrew at `/opt/homebrew/bin`; making them portable to Intel is a
welcome contribution.

## Build and run

    ./build.sh
    ditto build/LocalFlow.app /Applications/LocalFlow.app
    open /Applications/LocalFlow.app

`build.sh` prints the path of the bundle it produced. It pins the ad-hoc
signature to a stable designated requirement so macOS does not drop your
Accessibility grant on every rebuild — if you change the signing line, expect to
re-grant Accessibility after each build.

## Where code goes

    Sources/Core/            portable — Foundation only, no Apple frameworks
    Sources/Platform/macOS/  AppKit, Carbon, AVFoundation, ScreenCaptureKit, CoreAudio
    Sources/                 the macOS app itself: SwiftUI views and app state

**`Sources/Core` must keep compiling with nothing but Foundation.** CI builds it
on a Windows runner, so an `import AppKit` there turns your pull request red.
That is deliberate: the boundary is what makes a Windows port possible at all.

Importing only Foundation is not sufficient — a file can import Foundation and
still reference an Apple-backed type from elsewhere. Check with:

    swift build

`Sources/Core/PlatformCapabilities.swift` declares the protocols the OS layer
implements. If you need something new from the operating system, add a protocol
there with **no platform types in the signature**, then implement it under
`Platform/macOS`. If a signature needs an Apple type, the abstraction is wrong.

## Test

    swift test

One suite, and it runs everywhere Swift does. It needs no models, no microphone
and no network, it finishes in under a second, and **it must pass before you
open a pull request.** CI runs it on macOS and again on Windows.

There used to be a second, macOS-only suite. Every assertion in it tested
portable logic, so it could never fail on the platform it was guarding against;
it now lives in `Tests/Core/CoreTests.swift` and runs on both.

The remaining suites under `Tests/` exercise real audio, real models, or the
Claude CLI, so they are run by hand:

    xcrun swiftc -swift-version 5 -parse-as-library Sources/*.swift Sources/Core/*.swift Sources/Platform/macOS/*.swift Tests/Multilingual.swift -o build/multilingual -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech -framework Carbon -framework ScreenCaptureKit -framework CoreAudio -framework ServiceManagement -framework EventKit -framework UserNotifications
    ./build/multilingual

To check the Claude paths against a real signed-in `claude` CLI, build the smoke
suite without the app entry point and run `./build/smoke claude` for meeting
insights or `./build/smoke cleanup` for dictation cleanup:

    xcrun swiftc -swift-version 5 -parse-as-library Sources/Core/*.swift Sources/Platform/macOS/MeetingAudio.swift Sources/WhisperTranscription.swift Tests/Smoke.swift -o build/smoke -framework AVFoundation -framework Speech
    ./build/smoke cleanup

Anything that can only be checked by a human — permission prompts, the floating
widget, mouse buttons, an actual call — belongs in [VALIDATION.md](VALIDATION.md).
Please add what you verified there, and be honest about what you did *not* check.

## Code style

Match the file you are editing. In practice that means:

- Swift 5 language mode, four-space indentation, no trailing whitespace.
- One clear concern per file, and the file goes in the folder that matches how
  portable it is — see **Where code goes** above.
- Comments explain *why*, not *what*. The existing comment in `build.sh` about
  the designated requirement is the model to follow: it records a non-obvious
  reason a future reader would otherwise undo.
- No force-unwrapping in code paths a user can reach.
- User-facing strings are plain and specific. LocalFlow tells the user what
  failed and what to do; it does not say "Something went wrong".

## Pull requests

1. Branch off `main`.
2. Keep the change focused. One behaviour per PR.
3. Run `swift test`.
4. Describe what you changed, and say explicitly what you tested on which Mac
   and which macOS version.
5. If your change touches permissions, audio capture, or anything that leaves
   the machine, call that out in the description.

Small PRs get reviewed fast. Large architectural changes are much better started
as an issue.

## Good places to start

- Intel Mac and non-`/opt/homebrew` support in `build.sh` and
  `scripts/download-models.sh`.
- Additional languages beyond English and Romanian in the language router.
- A Homebrew cask so `brew install --cask localflow` works.
- Accessibility of the main window: VoiceOver labels, keyboard navigation.
- Anything in the **Status** section of the README that is still marked planned.

Issues tagged [`good first issue`](https://github.com/girzsebastian/LocalFlow/labels/good%20first%20issue)
are scoped small on purpose.

## Reporting bugs

Use the issue templates. A dictation bug is much easier to fix with the macOS
version, the Mac model, the language mode, and whether Accessibility was granted.
Never paste a transcript containing anything private — LocalFlow exists so that
text stays yours.

## Security

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).

## License and the CLA

LocalFlow is [MIT](LICENSE) and the application stays free and open.

**By opening a pull request you accept [CLA.md](CLA.md).** There is nothing to
sign and no bot to answer — the pull request template asks you to confirm you
have read it, and that is all.

**You keep the copyright to everything you write.** The agreement grants the
project a licence, including the right to distribute contributions under terms
other than MIT. That matters because server-backed features — syncing your
dictionary between machines, shared team vocabularies — may one day be offered
under different terms to fund the work, and that needs permission from every
copyright holder. Collected up front it costs one reply; collected two years and
twenty contributors later it is not collectable at all.

Nothing you contribute can be removed from the MIT-licensed version. What is
public stays public under MIT, permanently.

**Note for the maintainer:** the bot only sees pull requests. A patch applied by
hand from an issue, an email or a fork bypasses it entirely and lands unsigned
code in the history — which is exactly the hole the agreement exists to close.
Route contributions through pull requests, or collect the signature before
committing.
