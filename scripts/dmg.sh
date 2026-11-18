#!/usr/bin/env bash
# Package build/Cadence.app into a drag-to-Applications disk image.
# Usage: scripts/dmg.sh [version]   → build/Cadence-<version>.dmg
# Signs the image when CODESIGN_IDENTITY is set (needed before notarizing it).
source "$(dirname "$0")/common.sh"

APP="$BUILD/Cadence.app"
[[ -d "$APP" ]] || { echo "No $APP — run scripts/build.sh first" >&2; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="$BUILD/Cadence-$VERSION.dmg"
STAGE="$BUILD/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Cadence $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

echo "Built $DMG"
