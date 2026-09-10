#!/bin/zsh
# Walks you through capturing the screenshots the README expects.
#
# It has to be run by a human: macOS will not let a background process capture
# the screen, and half of these shots only exist while you are mid-dictation.
# The script handles the naming, the destination and the retina downscale so the
# only thing left is pointing at the right window.
set -euo pipefail
cd "${0:A:h}/.."

DEST="docs/images"
mkdir -p "$DEST"

capture() {
  local name="$1" prompt="$2"
  print -P "\n%F{cyan}── $name%f"
  echo "$prompt"
  echo -n "Press Return when the screen looks right, or s to skip: "
  read -r answer
  [[ "$answer" == "s" ]] && { echo "skipped"; return }

  echo "Now click the window you want. (Hold Option while clicking to drop the drop-shadow.)"
  screencapture -w -o "$DEST/$name.png"

  # README images are read on a laptop, not printed. Halving retina keeps them
  # sharp and takes a 2.5MB file under 600KB.
  local width=$(sips -g pixelWidth "$DEST/$name.png" | awk '/pixelWidth/{print $2}')
  if (( width > 1600 )); then
    sips -Z $(( width / 2 )) "$DEST/$name.png" >/dev/null
  fi
  local size=$(du -h "$DEST/$name.png" | cut -f1)
  echo "saved $DEST/$name.png ($size)"
}

cat <<'INTRO'
Capturing README screenshots.

Two things before you start:
  · Use a clean desktop. Anything on screen ends up on the internet.
  · Dictate something harmless. The transcript in the shot is public forever.
INTRO

capture "library" \
  "Open LocalFlow's main window with a few dictations in the library."

capture "widget-recording" \
  "Start a dictation and let the waveform move, then capture the floating widget.
   This is the one that shows what the app actually does — worth a retry to get right."

capture "notetaker" \
  "Open a Notetaker entry with a transcript and the You / Meeting participants labels."

capture "settings" \
  "Open Settings on the General tab."

capture "dictionary" \
  "Open the dictionary or snippets screen with a couple of rules in it."

echo
echo "Done. Captured:"
ls -1 "$DEST"/*.png 2>/dev/null | sed 's/^/  /' || echo "  nothing"
cat <<'NEXT'

Next: the README already references these paths, so they light up as soon as
they exist. Check the images for anything private before committing — an email
address or a client name in a transcript cannot be taken back once pushed.
NEXT
