#!/usr/bin/env bash
# Run the iPhone unit tests in the iOS Simulator: the shared CadenceCore suite plus iOS/Tests.
# Usage: scripts/ios-test.sh [--result-bundle PATH]
# Picks the newest available iPhone simulator; set IOS_SIMULATOR="iPhone 17" to choose one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT=""
[[ "${1:-}" == "--result-bundle" ]] && RESULT="$2"

if [[ -z "${IOS_SIMULATOR:-}" ]]; then
  # Newest iOS runtime first, first iPhone in it.
  IOS_SIMULATOR=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(n) for n in re.findall(r"\d+", runtime.split("iOS-")[-1])]
for runtime in sorted((r for r in devices if "iOS" in r), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"]); break
')
  [[ -n "$IOS_SIMULATOR" ]] || { echo "No iPhone simulator available" >&2; exit 1; }
  DEST="platform=iOS Simulator,id=$IOS_SIMULATOR"
else
  DEST="platform=iOS Simulator,name=$IOS_SIMULATOR"
fi
echo "Testing on $DEST"

ARGS=(-project "$ROOT/iOS/CadenceCompanion.xcodeproj" -scheme Cadence -configuration Debug
      -derivedDataPath "$ROOT/build/ios" -destination "$DEST"
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
if [[ -n "$RESULT" ]]; then rm -rf "$RESULT"; ARGS+=(-resultBundlePath "$RESULT"); fi
xcodebuild "${ARGS[@]}" test
