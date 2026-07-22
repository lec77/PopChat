#!/bin/bash
# Builds PopChat.app into dist/. SwiftPM produces the binary; this script wraps it
# in an app bundle (LSUIElement menu bar app) and signs it.
#
# Signing identity comes from POPCHAT_SIGN_IDENTITY; the default "-" is ad-hoc, which
# is right for local iteration. release.sh sets it to the Developer ID and that branch
# additionally enables the hardened runtime + a secure timestamp, both of which
# notarization refuses to proceed without.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
SIGN_ID="${POPCHAT_SIGN_IDENTITY:--}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/PopChat"
APP="dist/PopChat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopChat"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SPM dependency resource bundles (KeyboardShortcuts localizations, SwiftMath's math
# fonts) must ship inside the app for Bundle.module lookup to succeed — without them
# SwiftMath traps the first time a message contains LaTeX.
# -L is load-bearing: .build/<config> is a symlink to .build/<triple>/<config>, and
# plain find will not descend into it, so this silently copied nothing.
find -L ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

if [ -z "$(ls -A "$APP/Contents/Resources")" ]; then
    echo "error: no resource bundles were copied — LaTeX rendering would crash at runtime" >&2
    exit 1
fi

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
else
    # The nested *.bundle payloads are resource-only (localizations, math fonts, a
    # privacy manifest) — no Mach-O inside, so the app's own signature seals them and
    # signing them individually just fails on the ones lacking an Info.plist.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo "Built $APP (signed: $SIGN_ID)"
fi
echo "Run with: open $APP"
