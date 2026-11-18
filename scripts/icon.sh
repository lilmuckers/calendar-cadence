#!/usr/bin/env bash
# Regenerate Support/AppIcon.icns and the iPhone app icon from scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$ROOT/scripts/make-icon.swift" -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/icon-1024.png"
cp "$TMP/icon-1024.png" "$ROOT/Support/AppIcon.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Support/AppIcon.icns"
echo "Wrote Support/AppIcon.icns"
"$TMP/make-icon" "$ROOT/iOS/Cadence/Assets.xcassets/AppIcon.appiconset/AppIcon.png" --ios
echo "Wrote the iPhone app icon"
