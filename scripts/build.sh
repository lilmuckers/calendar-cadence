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

# Optional built-in Google OAuth client and Microsoft app registration, so users can just click "Sign in with Google".
# Read from the environment, or from the git-ignored Support/Secrets.env. Never committed.
if [[ -f "$ROOT/Support/Secrets.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$ROOT/Support/Secrets.env"; set +a
fi
if [[ -n "${GOOGLE_CLIENT_ID:-}" && -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CadenceGoogleClientID string $GOOGLE_CLIENT_ID" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :CadenceGoogleClientSecret string $GOOGLE_CLIENT_SECRET" "$PLIST"
  echo "Bundled Google OAuth client (${GOOGLE_CLIENT_ID:0:12}…)"
else
  echo "No Google OAuth client bundled; users enter their own in Settings → Accounts"
fi
if [[ -n "${MICROSOFT_CLIENT_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CadenceMicrosoftClientID string $MICROSOFT_CLIENT_ID" "$APP/Contents/Info.plist"
  echo "Bundled Microsoft app registration (${MICROSOFT_CLIENT_ID:0:8}…)"
else
  echo "No Microsoft app registration bundled; users enter their own in Settings → Accounts"
fi

codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" \
  --entitlements "$ROOT/Support/Cadence.entitlements" "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x Cadence 2>/dev/null || true
  open "$APP"
fi
