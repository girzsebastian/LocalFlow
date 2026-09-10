# Security Policy

## Supported versions

Softspoke is a young project. Only the latest release and `main` receive fixes.

## Reporting a vulnerability

**Please do not open a public issue.**

Report privately through GitHub Security Advisories:
<https://github.com/girzsebastian/Softspoke/security/advisories/new>

Please include what you can: affected version, macOS version, reproduction
steps, and the impact you believe it has. You will get an acknowledgement within
a few days, and credit in the release notes unless you would rather not be named.

## What is in scope

Softspoke's central promise is that speech audio stays on the machine. Anything
that breaks that is the highest-severity class of bug here:

- Microphone or system audio, transcripts, or archive contents leaving the Mac
  without an explicit user action.
- The local Whisper server (`WhisperServer.swift`) becoming reachable from
  outside `127.0.0.1`.
- Transcript text reaching the Claude CLI on a path the user did not choose.
- Escalation via the Accessibility grant the app requires for text insertion —
  for example inserting text into an application the user did not target.
- Anything readable in the local archive that a different user account on the
  same Mac should not be able to read.

## What is not in scope

- The app is **ad-hoc signed, not notarized**. The Gatekeeper warning on first
  launch is expected and documented, not a vulnerability.
- Whisper model files are downloaded from Hugging Face; `scripts/download-models.sh`
  verifies SHA-256 checksums. Report a checksum mismatch — that one matters.
- Vulnerabilities in `whisper.cpp`, `ffmpeg`, or the Claude CLI belong upstream,
  though a heads-up here is welcome if Softspoke's usage makes them worse.
