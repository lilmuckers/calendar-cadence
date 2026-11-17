#!/usr/bin/env bash
# Run the CadenceCore unit tests with Swift Testing.
source "$(dirname "$0")/common.sh"
CONFIG=debug OPT=(-Onone -g)
build_core

DEV=$(xcode-select -p)
if [[ -d "$DEV/Platforms/MacOSX.platform/Developer" ]]; then
  # Full Xcode layout
  FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
  INTEROP="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
  PLUGINS="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
else
  # Command Line Tools layout
  FW="$DEV/Library/Developer/Frameworks"
  INTEROP="$DEV/Library/Developer/usr/lib"
  PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
fi

cat > "$BUILD/TestMain.swift" <<'SWIFT'
import Testing
@main struct TestRunner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT

swiftc -target "$TARGET" -Onone -g -parse-as-library \
  -F "$FW" -I "$FW" -L "$FW" -plugin-path "$PLUGINS" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$INTEROP" \
  -I "$BUILD/core" -L "$BUILD/core" -lCadenceCore \
  -o "$BUILD/CadenceTests" \
  "$BUILD/TestMain.swift" "$ROOT"/Tests/CadenceCoreTests/*.swift

"$BUILD/CadenceTests" "$@"
