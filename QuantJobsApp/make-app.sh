#!/bin/bash
# Build a release binary and wrap it in a double-clickable QuantJobs.app.
set -euo pipefail

cd "$(dirname "$0")"
APP="${1:-$HOME/Applications/QuantJobs.app}"

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

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
