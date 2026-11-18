#!/usr/bin/env bash
# Build the iPhone app. Usage:
#   scripts/ios-build.sh            # Simulator build into build/ios (no signing needed)
#   scripts/ios-build.sh --device   # Device build (needs DEVELOPMENT_TEAM in iOS/Config/Local.xcconfig)
# Open iOS/CadenceCompanion.xcodeproj in Xcode to run on a phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
ARGS=(-project "$ROOT/iOS/CadenceCompanion.xcodeproj" -scheme Cadence -configuration "$CONFIG" -derivedDataPath "$ROOT/build/ios")

if [[ "${1:-}" == "--device" ]]; then
  xcodebuild "${ARGS[@]}" -destination 'generic/platform=iOS' -allowProvisioningUpdates build
  echo "Built $ROOT/build/ios/Build/Products/$CONFIG-iphoneos/Cadence.app"
else
  xcodebuild "${ARGS[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
  echo "Built $ROOT/build/ios/Build/Products/$CONFIG-iphonesimulator/Cadence.app"
fi
