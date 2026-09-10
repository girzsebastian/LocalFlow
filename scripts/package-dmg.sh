#!/bin/zsh
# Packages build/Softspoke.app into a distributable .dmg.
#
# A disk image is the install people expect on a Mac: open it, drag the app onto
# the Applications shortcut, done. The zip we shipped before left the app
# wherever the browser downloaded it, which is how you end up running Softspoke
# out of ~/Downloads and losing its Accessibility grant on every update.
set -euo pipefail
cd "${0:A:h}/.."

APP="build/Softspoke.app"
[[ -d "$APP" ]] || { echo "Build first: ./build.sh" >&2; exit 1 }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Softspoke-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf -- "$STAGING"' EXIT

# ditto rather than cp: it preserves the code signature and extended attributes.
ditto "$APP" "$STAGING/Softspoke.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Softspoke $VERSION" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

# Verify what we are about to hand people: the image mounts, and the app inside
# it is the signed bundle rather than a mangled copy.
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
codesign --verify --strict "$MOUNT/Softspoke.app"
[[ -L "$MOUNT/Applications" ]] || { hdiutil detach "$MOUNT" -quiet; echo "missing /Applications shortcut" >&2; exit 1 }
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "$DMG"
