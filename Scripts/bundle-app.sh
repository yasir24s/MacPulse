#!/bin/bash
# Wrap the SwiftPM executable into a real .app bundle.
#
# Same approach as Auscult: SwiftUI needs a bundle for MenuBarExtra to behave,
# and building this way keeps the project command-line buildable with no
# .xcodeproj to maintain -- which also keeps DerivedData at zero, worth caring
# about on a volume this full.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product MacPulseApp
swift build -c "$CONFIG" --product macpulsed

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/MacPulse.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN_DIR/MacPulseApp" "$APP/Contents/MacOS/MacPulse"
# Ship the daemon inside the bundle so app and daemon can never drift apart;
# the installer copies it out to /usr/local/libexec.
cp "$BIN_DIR/macpulsed" "$APP/Contents/Helpers/macpulsed"

cp "$ROOT/Resources/MacPulse.icns"            "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuBarTemplate.png"      "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuBarTemplate@2x.png"   "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuBarTemplate@3x.png"   "$APP/Contents/Resources/"

# The installer travels inside the app so its "Update daemon..." button always
# installs the helper built alongside it -- app and daemon cannot drift. The
# script locates Helpers/macpulsed relative to itself when run from here.
cp "$ROOT/Scripts/install-daemon.sh"          "$APP/Contents/Resources/install-daemon.sh"
cp "$ROOT/launchd/com.yasir.macpulse.plist"   "$APP/Contents/Resources/com.yasir.macpulse.plist"
chmod 755 "$APP/Contents/Resources/install-daemon.sh"

BUILD_STAMP="$(date '+%Y-%m-%d %H:%M')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MacPulse</string>
    <key>CFBundleDisplayName</key>       <string>MacPulse</string>
    <key>CFBundleIdentifier</key>        <string>com.yasir.macpulse</string>
    <key>CFBundleExecutable</key>        <string>MacPulse</string>
    <key>CFBundleIconFile</key>          <string>MacPulse</string>
    <key>CFBundleIconName</key>          <string>MacPulse</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Menu bar only: no Dock tile, no window on launch. -->
    <key>LSUIElement</key>               <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>  <string>MacPulse — live Mac telemetry</string>
    <key>MacPulseBuildStamp</key>        <string>$BUILD_STAMP</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null \
    && echo "Signed ad-hoc." \
    || echo "Warning: ad-hoc signing failed; the app may still run."

echo "Built $APP"
