#!/usr/bin/env bash
# Build Cadence.app into ./build. Usage: scripts/build.sh [--run]
# Set CODESIGN_IDENTITY to a "Developer ID"/"Apple Development" identity to keep the calendar
# permission across rebuilds; the default ad-hoc signature changes each build, so macOS may re-ask.
source "$(dirname "$0")/common.sh"
build_core

APP="$BUILD/Cadence.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -target "$TARGET" "${OPT[@]}" -parse-as-library -module-name Cadence \
  -I "$BUILD/core" -L "$BUILD/core" -lCadenceCore \
  -framework AppKit -framework SwiftUI -framework EventKit -framework MapKit \
  -framework CoreLocation -framework ServiceManagement \
  -o "$APP/Contents/MacOS/Cadence" \
  $(find "$ROOT/Sources/Cadence" -name '*.swift')

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Support/AppIcon.icns" ]] && cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/"

codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" \
  --entitlements "$ROOT/Support/Cadence.entitlements" "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x Cadence 2>/dev/null || true
  open "$APP"
fi
