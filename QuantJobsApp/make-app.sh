#!/bin/bash
# Build a release binary and wrap it in a double-clickable QuantJobs.app.
#
#   ./make-app.sh                 install to /Applications and show it in Finder
#   ./make-app.sh --dmg           build QuantJobs.dmg to hand to someone else
#   ./make-app.sh --to <path>     put the .app somewhere specific
#   ./make-app.sh --no-reveal     skip the Finder window
set -euo pipefail

cd "$(dirname "$0")"

APP="/Applications/QuantJobs.app"
REVEAL=1
DMG=""

while [ $# -gt 0 ]; do
    case "$1" in
        # Only take the next argument as a path if it isn't another flag,
        # or a bare `--dmg --no-reveal` names its image "--no-reveal".
        --dmg)        if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
                          DMG="$2"; shift
                      else
                          DMG="$PWD/QuantJobs.dmg"
                      fi ;;
        --to)         APP="$2"; shift ;;
        --no-reveal)  REVEAL=0 ;;
        -h|--help)    sed -n '2,7p' "$0"; exit 0 ;;
        *)            echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# A disk image is built from a throwaway copy, never from /Applications.
STAGE=""
if [ -n "$DMG" ]; then
    STAGE="$(mktemp -d)/QuantJobs"
    trap 'rm -rf "$(dirname "$STAGE")"' EXIT
    APP="$STAGE/QuantJobs.app"
    mkdir -p "$STAGE"
elif ! mkdir -p "$(dirname "$APP")" 2>/dev/null || [ ! -w "$(dirname "$APP")" ]; then
    # /Applications needs a writable spot; fall back to the user's own folder.
    APP="$HOME/Applications/QuantJobs.app"
    mkdir -p "$(dirname "$APP")"
fi

# The bundle carries its own copy of the config, used to seed a fresh install
# that isn't sitting in a checkout. Refresh it from the repo first, or an app
# installed to /Applications ships whatever defaults were current the last time
# anyone thought to copy them by hand.
for f in companies categories locations; do
    cp "../$f.json" "Sources/QuantJobs/Resources/$f.json"
done

# One source of truth for the version: the updater compares what the running
# bundle reports against the latest release tag, so a hardcoded Info.plist that
# drifts from the tag makes it either miss updates or offer one forever.
VERSION=$(tr -d '[:space:]' < ../VERSION)
[ -n "$VERSION" ] || { echo "VERSION file is empty" >&2; exit 1; }

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/QuantJobs" "$APP/Contents/MacOS/QuantJobs"

# SPM puts the target's resources in a side bundle; Bundle.module finds it
# next to the executable or in Contents/Resources.
if [ -d "$BIN/QuantJobs_QuantJobs.bundle" ]; then
    cp -R "$BIN/QuantJobs_QuantJobs.bundle" "$APP/Contents/Resources/"
fi

# Icon: regenerate only if it's missing, since drawing it takes a few seconds.
if [ ! -f Icon/QuantJobs.icns ]; then
    ( cd Icon && swift make-icon.swift QuantJobs.iconset >/dev/null \
        && iconutil -c icns QuantJobs.iconset -o QuantJobs.icns )
fi
cp Icon/QuantJobs.icns "$APP/Contents/Resources/QuantJobs.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>QuantJobs</string>
    <key>CFBundleDisplayName</key>       <string>Quant Jobs</string>
    <key>CFBundleExecutable</key>        <string>QuantJobs</string>
    <key>CFBundleIconFile</key>          <string>QuantJobs.icns</string>
    <key>CFBundleIdentifier</key>        <string>local.quantjobs.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# ── Disk image ──────────────────────────────────────────────────────────
# The drag-here-to-install layout people expect: the app, a symlink to
# /Applications, and a note about the Gatekeeper prompt they'll hit first.
if [ -n "$DMG" ]; then
    ln -s /Applications "$STAGE/Applications"

    cat > "$STAGE/Read me first.txt" <<'TXT'
QuantJobs

1. Drag QuantJobs.app onto the Applications folder here.
2. Open it. macOS will refuse the first time, because this app isn't notarised
   -- that needs a paid Apple developer account. The dialog offers only
   "Move to Trash" or "Done":

     - Click DONE. Not Move to Trash.
     - Go to System Settings > Privacy & Security and scroll to Security.
       A line there says QuantJobs was blocked, with an "Open Anyway" button.
     - Click it, authenticate, and it opens. You are never asked again.

   (On macOS 14 and earlier you can instead right-click the app and choose
   Open, which does it in one step. macOS 15 removed that shortcut.)
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
    [ "$REVEAL" = "1" ] && open -R "$DMG"
    exit 0
fi

echo "built $APP"

# Let Finder and Spotlight notice it, then show it to the user.
/usr/bin/touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true
# An `&&` here would exit 1 whenever REVEAL is 0, which under `set -e` would
# abort a caller mid-build.
if [ "$REVEAL" = "1" ]; then
    open -R "$APP"
fi
