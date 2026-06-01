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

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Mac Charge Power</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
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
