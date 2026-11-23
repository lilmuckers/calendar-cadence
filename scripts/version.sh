#!/usr/bin/env bash
# Works out the version the apps are stamped with. Source it, or run it to print "VERSION BUILD_NUMBER".
#
#   VERSION       the X.Y.Z of the newest vX.Y.Z tag reachable from HEAD (the release workflow sets it
#                 to the version it's about to tag). Falls back to Support/Info.plist without tags.
#   BUILD_NUMBER  the number of commits on HEAD (the release workflow sets it from the run number).
#
# Both can be set in the environment to override.
_VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git -C "$_VERSION_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$_VERSION_ROOT/Support/Info.plist")"
  fi
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$(git -C "$_VERSION_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi
export VERSION BUILD_NUMBER

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "$VERSION $BUILD_NUMBER"
fi
