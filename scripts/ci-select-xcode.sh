#!/usr/bin/env bash
# Switch a GitHub macOS runner to the Xcode the project is developed with.
# Usage: scripts/ci-select-xcode.sh [VERSION]   (default: $XCODE_VERSION, e.g. "27.2" or "27")
# Picks /Applications/Xcode_<VERSION>.app, or the newest Xcode_<VERSION>.x.app if only a prefix is given.
# Fails, listing what's installed, if there's no match, so a missing version never silently falls back.
set -euo pipefail
WANT="${1:-${XCODE_VERSION:?Set XCODE_VERSION or pass a version}}"

pick=""
if [[ -d "/Applications/Xcode_$WANT.app" ]]; then
  pick="/Applications/Xcode_$WANT.app"
else
  pick=$(ls -d /Applications/Xcode_"$WANT".*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1 || true)
fi

if [[ -z "$pick" ]]; then
  echo "::error::Xcode $WANT isn't installed on this runner. Installed:"
  ls -d /Applications/Xcode*.app
  exit 1
fi

sudo xcode-select -s "$pick/Contents/Developer"
echo "Selected $pick"
xcodebuild -version
