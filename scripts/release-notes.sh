#!/usr/bin/env bash
# Fill .github/RELEASE_NOTES_TEMPLATE.md for a release.
# Usage: scripts/release-notes.sh <tag> <previous-tag-or-empty> <bump> <notarized:true|false> <checksums-file> > notes.md
# Needs gh authenticated (GH_TOKEN), GH_REPO or a git remote, and git history with tags. The tag needn't exist yet, so this can
# preview notes locally; the changelog then runs up to TARGET (default: HEAD, which must be pushed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="$1" PREV_TAG="$2" BUMP="$3" NOTARIZED="$4" CHECKSUMS_FILE="$5"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# Merged PRs grouped by build (mac / ios / website / ci / docs labels), then by release label.
CHANGELOG="$(GH_REPO="$REPO" python3 -I "$ROOT/scripts/changelog.py" "$TAG" "$PREV_TAG" --target-ref "${TARGET:-HEAD}")"

if [[ "$NOTARIZED" == "true" ]]; then
  SIGNING_NOTE="> [!NOTE]
> Signed with a Developer ID and notarized by Apple."
else
  SIGNING_NOTE="> [!WARNING]
> This build is **not notarized** (ad-hoc signed), so macOS will refuse to open it at first.
> After dragging it to Applications, open it once, then choose **Open Anyway** in *System Settings → Privacy & Security*,
> or run \`xattr -dr com.apple.quarantine /Applications/Cadence.app\`."
fi

[[ "$BUMP" == "initial" ]] && BUMP="first"
export VERSION="${TAG#v}" TAG PREV_TAG BUMP CHANGELOG SIGNING_NOTE
DATE="$(date -u +%Y-%m-%d)"; export DATE
CHECKSUMS="$(cat "$CHECKSUMS_FILE")"; export CHECKSUMS

# Literal substitution (the changelog can contain any characters), and drop the template's comment header.
python3 -I - "$ROOT/.github/RELEASE_NOTES_TEMPLATE.md" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"\A<!--.*?-->\n", "", text, flags=re.S)
for key in ("VERSION", "TAG", "PREVIOUS_TAG", "DATE", "BUMP", "CHANGELOG", "SIGNING_NOTE", "CHECKSUMS"):
    env = "PREV_TAG" if key == "PREVIOUS_TAG" else key
    text = text.replace("{{" + key + "}}", os.environ.get(env, ""))
sys.stdout.write(text)
PY
