#!/usr/bin/env bash
# Sync the main checkout with GitHub main, build the Mac and iPhone apps there,
# install the iPhone app on your phone and relaunch the Mac app.
#
# Usage: scripts/sync-deploy.sh [--skip-pull] [--skip-ios] [--skip-mac] [--device NAME|UDID]
#
# Always works in the repository's main checkout (the first `git worktree list` entry),
# even when run from a Claude Code worktree. The phone defaults to the first paired physical
# iPhone; set CADENCE_IPHONE or pass --device to pick one.
# Set CODESIGN_IDENTITY (e.g. in ~/.zshrc) so the Mac app keeps its permissions across builds.
set -euo pipefail

SKIP_PULL=0 SKIP_IOS=0 SKIP_MAC=0
DEVICE="${CADENCE_IPHONE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-pull) SKIP_PULL=1 ;;
    --skip-ios)  SKIP_IOS=1 ;;
    --skip-mac)  SKIP_MAC=1 ;;
    --device)    DEVICE="${2:?--device needs a name or UDID}"; shift ;;
    -h|--help)   sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$HERE" worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -d "$ROOT" ]] || { echo "Couldn't find the main checkout" >&2; exit 1; }
cd "$ROOT"
echo "==> Main checkout: $ROOT"

# 1. Sync with GitHub main
if [[ $SKIP_PULL == 0 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Main checkout has uncommitted changes; commit or stash them first (or pass --skip-pull)." >&2
    exit 1
  fi
  if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "==> Switching main checkout to main"
    git switch main
  fi
  echo "==> Pulling origin/main"
  git fetch origin main
  git merge --ff-only origin/main
fi
echo "==> At $(git log --oneline -1)"

[[ -z "${CODESIGN_IDENTITY:-}" ]] && echo "warning: CODESIGN_IDENTITY not set; Mac app will be ad-hoc signed and macOS may re-ask for permissions" >&2

# 2. Build both (iPhone in the background, Mac in the foreground)
LOGDIR="$ROOT/build"; mkdir -p "$LOGDIR"
IOS_LOG="$LOGDIR/ios-device-build.log"
IOS_PID=""
if [[ $SKIP_IOS == 0 ]]; then
  echo "==> Building iPhone app (log: $IOS_LOG)"
  "$ROOT/scripts/ios-build.sh" --device >"$IOS_LOG" 2>&1 &
  IOS_PID=$!
fi
if [[ $SKIP_MAC == 0 ]]; then
  echo "==> Building Mac app"
  "$ROOT/scripts/build.sh"
fi
if [[ -n "$IOS_PID" ]]; then
  if ! wait "$IOS_PID"; then
    grep -E "error:" "$IOS_LOG" | head -20 >&2 || true
    echo "iPhone build failed; see $IOS_LOG" >&2
    exit 1
  fi
  echo "==> iPhone build succeeded"
fi

# 3. Install on the iPhone
if [[ $SKIP_IOS == 0 ]]; then
  if [[ -z "$DEVICE" ]]; then
    JSON="$(mktemp)"; trap 'rm -f "$JSON"' EXIT
    xcrun devicectl list devices --json-output "$JSON" >/dev/null
    DEVICE="$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print(hw.get("udid") or d["identifier"]); break
' "$JSON")"
    [[ -n "$DEVICE" ]] || { echo "No paired iPhone found; pass --device" >&2; exit 1; }
  fi
  APP="$ROOT/build/ios/Build/Products/${CONFIG:-Debug}-iphoneos/Cadence.app"
  echo "==> Installing on $DEVICE"
  ok=0
  for attempt in 1 2 3; do
    if xcrun devicectl device install app --device "$DEVICE" "$APP"; then ok=1; break; fi
    echo "Install attempt $attempt failed; unlock the phone and keep it on Wi-Fi or USB. Retrying in 5 s…" >&2
    sleep 5
  done
  [[ $ok == 1 ]] || { echo "Couldn't install on the iPhone. Rerun with --skip-pull --skip-mac once it's reachable." >&2; exit 1; }
fi

# 4. Relaunch the Mac app
if [[ $SKIP_MAC == 0 ]]; then
  echo "==> Relaunching Cadence"
  pkill -x Cadence 2>/dev/null || true
  sleep 2
  open "$ROOT/build/Cadence.app"
fi
echo "==> Done"
