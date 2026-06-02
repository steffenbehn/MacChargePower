#!/bin/bash
# Build MacChargePower into a runnable .app bundle (no Xcode project needed).
#   ./build.sh        build only
#   ./build.sh run     build, then (re)launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="MacChargePower"
BUNDLE="build/$APP.app"
BIN="$BUNDLE/Contents/MacOS/$APP"
ID="de.steffenbehn.macchargepower"
VERSION="1.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

echo "Compiling…"
swiftc -O -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -o "$BIN" Sources/main.swift

echo "Bundling icon…"
mkdir -p "$BUNDLE/Contents/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
A="Assets.xcassets/AppIcon.appiconset"
cp "$A/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$A/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$A/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$A/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$A/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$A/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$A/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$A/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$A/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$A/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Mac Charge Power</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Steffen Behn</string>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)…"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "Built $BUNDLE"

if [ "${1:-}" = "run" ]; then
  pkill -x "$APP" 2>/dev/null || true
  open "$BUNDLE"
  echo "Launched — look for the ⚡ in the menu bar."
fi
