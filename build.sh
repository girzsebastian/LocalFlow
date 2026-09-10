#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/Softspoke.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O Sources/*.swift Sources/Core/*.swift Sources/Platform/macOS/*.swift -o "$APP/Contents/MacOS/Softspoke" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Speech -framework Carbon -framework ScreenCaptureKit -framework CoreAudio -framework ServiceManagement -framework EventKit -framework UserNotifications
cp Info.plist "$APP/Contents/Info.plist"
# Keep a stable designated requirement between local builds. Without it, an
# ad-hoc signature defaults to the executable's changing CDHash and macOS can
# leave a stale Accessibility entry enabled for the previous build.
#
# This identifier must stay identical to CFBundleIdentifier in Info.plist.
# macOS keys the Accessibility grant on the pair, so changing one alone makes
# every rebuild look like a different app.
codesign --force --sign - --requirements '=designated => identifier "io.github.girzsebastian.softspoke"' "$APP"
echo "$APP"
