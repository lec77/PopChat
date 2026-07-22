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

WORK=$(mktemp -d)          # scratch: the upload zip, never packaged
STAGE=$(mktemp -d)         # exactly what lands in the disk image
trap 'rm -rf "$WORK" "$STAGE"' EXIT

# The app is notarized and stapled BEFORE it is packaged, so the copy the user drags
# to /Applications carries its own ticket. Notarizing only the .dmg leaves the app
# inside ticketless: Gatekeeper then has to reach Apple on first launch, and a user
# who is offline is refused. ditto, not zip — it is what preserves bundle symlinks.
echo "==> Notarizing the app (Apple's service; usually under two minutes)"
ditto -c -k --keepParent "$APP" "$WORK/PopChat.zip"
xcrun notarytool submit "$WORK/PopChat.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Staging disk image"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
rm -f "$DMG"
hdiutil create -volname "PopChat" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"

echo "==> Signing disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# The image is notarized in its own right too, so the download itself is trusted
# rather than merely containing something trusted.
echo "==> Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying as Gatekeeper would on a first launch elsewhere"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo
echo "Notarized: $DMG"
echo "Attach it to a release with:"
echo "  gh release create v$VERSION \"$DMG\" --title \"PopChat $VERSION\" --notes-file <notes.md>"
