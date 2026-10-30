#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# UNIVERSAL=1 builds for both Apple silicon and Intel (used for releases).
BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Throat"
APP="$PWD/build/Throat.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Throat"
cp Support/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# VERSION (e.g. 1.2.0) stamps the bundle version; releases pass the git tag.
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi
# Prefer a persistent certificate: ad-hoc signatures change identity on every rebuild,
# invalidating macOS privacy grants. SIGNING_IDENTITY can override the automatic choice.
IDENTITY="${SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "Warning: no development certificate found; ad-hoc rebuilds may require granting permissions again." >&2
    IDENTITY="-"
fi
if [[ "$IDENTITY" == *"Developer ID"* ]]; then
    # Distribution builds need the hardened runtime and a secure timestamp for notarization.
    codesign --force --options runtime --timestamp --entitlements Support/Throat.entitlements --sign "$IDENTITY" "$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
