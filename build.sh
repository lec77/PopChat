#!/bin/bash
# Builds PopChat.app into dist/. SwiftPM produces the binary; this script wraps it
# in an app bundle (LSUIElement menu bar app) and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/PopChat"
APP="dist/PopChat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopChat"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SPM dependency resource bundles (e.g. KeyboardShortcuts localizations) must ship
# inside the app for Bundle.module lookup to succeed.
find ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Run with: open $APP"
