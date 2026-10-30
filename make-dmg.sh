#!/bin/bash
# Packages build/Throat.app into build/Throat-<version>.dmg with a drag-to-Applications layout.
# Signs the DMG when SIGNING_IDENTITY is a Developer ID, and notarizes it when
# NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD (an app-specific password) are set.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Throat.app
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/Throat-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Throat -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null

if [[ "${SIGNING_IDENTITY:-}" == *"Developer ID"* ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
fi
echo "Built $DMG"
