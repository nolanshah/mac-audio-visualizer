#!/bin/zsh
# Builds Visualizer.app (release), signs it, and optionally launches it: ./build.sh [run]
# VERSION=1.2.3 sets the bundle version (CI passes the release tag).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=Visualizer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Visualizer "$APP/Contents/MacOS/Visualizer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.visualizer</string>
    <key>CFBundleName</key><string>Visualizer</string>
    <key>CFBundleDisplayName</key><string>Visualizer</string>
    <key>CFBundleExecutable</key><string>Visualizer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAudioCaptureUsageDescription</key><string>Visualizer listens to your Mac's audio output to animate the visuals.</string>
    <key>NSAppleEventsUsageDescription</key><string>Visualizer reads the current Spotify track and artwork to color the visuals.</string>
</dict>
</plist>
PLIST

# Sign with a real identity when available: macOS ties the Screen & System Audio Recording
# permission to the signature, and ad-hoc signatures change on every build (re-prompting each time).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: no signing identity found; ad-hoc signing (permission prompts will repeat after rebuilds)"
    codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
