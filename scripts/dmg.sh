#!/usr/bin/env bash
# Package build/Cadence.app into a styled drag-to-Applications disk image.
# Usage: scripts/dmg.sh [version]   → build/Cadence-<version>.dmg
# Uses dmgbuild (installed into build/.dmg-venv on first run) to lay out the window without driving Finder,
# so it works the same on CI. Signs the image when CODESIGN_IDENTITY is set (needed before notarizing it).
source "$(dirname "$0")/common.sh"
DMGBUILD_VERSION="1.6.7"

APP="$BUILD/Cadence.app"
[[ -d "$APP" ]] || { echo "No $APP — run scripts/build.sh first" >&2; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="$BUILD/Cadence-$VERSION.dmg"
WORK="$BUILD/dmg"
rm -rf "$WORK" "$DMG"
mkdir -p "$WORK"

# Background at 1x and 2x, combined into one HiDPI TIFF that Finder picks the right size from.
swiftc -O "$ROOT/scripts/make-dmg-background.swift" -o "$WORK/make-background"
"$WORK/make-background" "$WORK/background.png" 1
"$WORK/make-background" "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

VENV="$BUILD/.dmg-venv"
if ! "$VENV/bin/python" -c "import dmgbuild" 2>/dev/null; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
  -D app="$APP" -D background="$WORK/background.tiff" -D volume_icon="$ROOT/Support/AppIcon.icns" \
  "Cadence $VERSION" "$DMG"
rm -rf "$WORK"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

echo "Built $DMG"
