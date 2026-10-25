#!/bin/bash
# Builds build/Pilotlight.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=build/Pilotlight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/Pilotlight" "$BIN/pilot" "$APP/Contents/MacOS/"

codesign --force --sign - "$APP/Contents/MacOS/pilot"
codesign --force --sign - "$APP"
echo "Built $APP"
