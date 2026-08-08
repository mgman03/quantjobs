#!/bin/bash
# Screenshot the running QuantJobs window.
#
#   ./shot.sh                 write /tmp/quantjobs-shot.png
#   ./shot.sh out.png         write somewhere specific
#   ./shot.sh out.png 1500    and downscale to 1500px wide
#
# Captures the window by id rather than the screen, which means it does not
# raise the app, steal focus, or catch whatever else is on the desktop. Works
# while the window is behind others; does not work while the screen is locked
# (screencapture silently returns the lock screen).
#
# Needs Screen Recording permission for the terminal running this. It does NOT
# need Accessibility — that's only for driving the UI, not seeing it.
set -euo pipefail

OUT="${1:-/tmp/quantjobs-shot.png}"
WIDTH="${2:-}"

# The window id comes from a tiny Swift helper, compiled on first use.
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Tools/window-id.swift"
BIN="$HERE/Tools/.window-id"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    swiftc -O "$SRC" -o "$BIN" 2>/dev/null || {
        echo "couldn't build $SRC (need Xcode command-line tools)" >&2; exit 1; }
fi

id=$("$BIN" "Quant Jobs" || true)

if [ -z "$id" ] || [ "$id" = "0" ]; then
    echo "no QuantJobs window on screen — is the app running?" >&2
    exit 1
fi

screencapture -x -o -l "$id" "$OUT"
[ -s "$OUT" ] || { echo "capture failed (Screen Recording permission?)" >&2; exit 1; }

if [ -n "$WIDTH" ]; then
    sips -Z "$WIDTH" "$OUT" --out "$OUT" >/dev/null
fi
echo "$OUT  ($(sips -g pixelWidth -g pixelHeight "$OUT" | awk '/pixel/{printf "%s ", $2}'))"
