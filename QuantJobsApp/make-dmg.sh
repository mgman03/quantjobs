#!/bin/bash
# Build QuantJobs.app and wrap it in a double-clickable disk image.
#
#   ./make-dmg.sh            → QuantJobs.dmg next to this script
#   ./make-dmg.sh ~/Desktop  → somewhere else
#
# The image contains the app and a symlink to /Applications, which is the
# drag-here-to-install layout people expect on macOS.
set -euo pipefail

cd "$(dirname "$0")"
OUT_DIR="${1:-$PWD}"
DMG="$OUT_DIR/QuantJobs.dmg"
STAGE="$(mktemp -d)/QuantJobs"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

# Build the app into the staging folder rather than ~/Applications.
./make-app.sh "$STAGE/QuantJobs.app" --no-reveal

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read me first.txt" <<'TXT'
QuantJobs

1. Drag QuantJobs.app onto the Applications folder here.
2. First launch: right-click the app and choose Open. macOS blocks
   double-clicking an app that isn't notarised by an Apple developer account,
   and right-click → Open is the standard way past that. You only do it once.
3. That's it. The app ships with its own copy of the firm list and settles it
   into ~/Library/Application Support/QuantJobs on first launch, so there is
   nothing else to download and no folder permission to grant.

To share one config with the command-line tool instead, clone the repo and
point the app at your checkout:

   defaults write local.quantjobs.shared configDirectory ~/quant-internships

Keep that checkout out of ~/Desktop, ~/Documents and ~/Downloads — macOS gates
those three, and the app will ask permission every time it is rebuilt.

Source and docs: https://github.com/mgman03/quantjobs
TXT

rm -f "$DMG"
hdiutil create -quiet -volname "QuantJobs" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"

echo "built $DMG ($(du -h "$DMG" | cut -f1))"
open -R "$DMG"
