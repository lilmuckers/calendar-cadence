#!/usr/bin/env bash
# Shared settings for building Cadence with plain swiftc (no SwiftPM / Xcode required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
CONFIG="${CONFIG:-release}"

if [[ "$CONFIG" == "debug" ]]; then
  OPT=(-Onone -g -DDEBUG)
else
  OPT=(-O)
fi

mkdir -p "$BUILD"

# Compile CadenceCore into a static library + module that the app and tests import.
build_core() {
  local out="$BUILD/core"
  mkdir -p "$out"
  swiftc -target "$TARGET" "${OPT[@]}" -enable-testing -parse-as-library \
    -module-name CadenceCore -emit-library -static -emit-module \
    -emit-module-path "$out/CadenceCore.swiftmodule" \
    -o "$out/libCadenceCore.a" \
    "$ROOT"/Sources/CadenceCore/*.swift
}
