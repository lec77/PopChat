#!/bin/bash
# Produces a notarized, stapled PopChat-<version>.dmg in dist/ — the artifact to attach
# to a GitHub Release. Unlike an ad-hoc build, this one opens on someone else's Mac
# without a Gatekeeper detour.
#
# One-time setup (interactive, stores an app-specific password in the login keychain):
#
#   xcrun notarytool store-credentials popchat \
#       --apple-id <your-apple-id> --team-id 322TD85UJS --password <app-specific-password>
#
# App-specific passwords come from appleid.apple.com → Sign-In and Security.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${POPCHAT_SIGN_IDENTITY:-Developer ID Application: Le Chen (322TD85UJS)}"
PROFILE="${POPCHAT_NOTARY_PROFILE:-popchat}"

APP="dist/PopChat.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/PopChat-$VERSION.dmg"

echo "==> Building and signing $VERSION"
POPCHAT_SIGN_IDENTITY="$IDENTITY" ./build.sh release

echo "==> Staging disk image"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

rm -f "$DMG"
hdiutil create -volname "PopChat" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"

echo "==> Signing disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (Apple's service; usually under two minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
# Staples the ticket into the .dmg so it validates offline, then confirms Gatekeeper
# accepts the app the way a first launch on someone else's Mac would.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo
echo "Notarized: $DMG"
echo "Attach it to a release with:"
echo "  gh release create v$VERSION \"$DMG\" --title \"PopChat $VERSION\" --notes-file <notes.md>"
