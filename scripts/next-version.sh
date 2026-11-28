#!/usr/bin/env bash
# Work out the next release version from the labels on PRs merged since the last release tag.
#
#   major > minor > patch — the highest label among the merged PRs wins.
#   PRs with none of those labels count as patch (and are listed as a warning).
#   With no release tag yet, the first release uses CFBundleShortVersionString from Support/Info.plist.
#
# Usage: scripts/next-version.sh [auto|major|minor|patch]   (default auto: decide from labels)
#
# PR test builds (the Release workflow's "pr" input) set INCLUDE_PR=<n> and BUILD_NUMBER. Then:
#   - the previous release is the last full one: the newest published release that isn't a draft or
#     pre-release and whose tag is on main (draft releases and test builds don't count);
#   - PR <n> (not merged) counts towards the bump;
#   - the tag is v<version>-pr.<n>.<build>, so a test build never takes the tag the real release will.
# Needs: git history with tags (fetch-depth: 0), gh authenticated (GH_TOKEN in CI).
# Prints key=value lines (version, tag, previous_tag, bump, prs) and appends them to $GITHUB_OUTPUT when set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDE="${1:-auto}"
BASE_BRANCH="${BASE_BRANCH:-main}"

case "$OVERRIDE" in auto|major|minor|patch) ;; *)
  echo "Unknown bump '$OVERRIDE' (expected auto, major, minor or patch)" >&2; exit 1 ;;
esac

release_tags() { git -C "$ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; }
if [[ -n "${INCLUDE_PR:-}" ]]; then
  FULL_RELEASES="$(gh release list --limit 200 --json tagName,isDraft,isPrerelease \
    --jq '.[] | select((.isDraft or .isPrerelease) | not) | .tagName')"
  PREV_TAG=""
  for t in $(release_tags); do
    grep -qxF "$t" <<<"$FULL_RELEASES" || continue
    git -C "$ROOT" merge-base --is-ancestor "$t^{commit}" "origin/$BASE_BRANCH" || continue
    PREV_TAG="$t"; break
  done
else
  PREV_TAG="$(release_tags | head -n1)"
fi

# Merged PRs since the previous tag, with their labels.
SEARCH="is:merged base:$BASE_BRANCH"
if [[ -n "$PREV_TAG" ]]; then
  SINCE="$(TZ=UTC git -C "$ROOT" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "$PREV_TAG^{commit}")"
  SEARCH="$SEARCH merged:>$SINCE"
fi
PRS_JSON="$(gh pr list --state merged --base "$BASE_BRANCH" --search "$SEARCH" --limit 1000 \
  --json number,title,labels)"
# A PR test build counts the (unmerged) PR too.
if [[ -n "${INCLUDE_PR:-}" ]]; then
  EXTRA="$(gh pr view "$INCLUDE_PR" --json number,title,labels)"
  PRS_JSON="$(jq --argjson pr "$EXTRA" 'map(select(.number != $pr.number)) + [$pr]' <<<"$PRS_JSON")"
fi
PR_COUNT="$(jq 'length' <<<"$PRS_JSON")"

highest_label() {
  jq -r '[.[].labels[].name] as $l
    | if ($l | index("major")) then "major"
      elif ($l | index("minor")) then "minor"
      elif ($l | index("patch")) then "patch"
      else "patch" end' <<<"$PRS_JSON"
}

UNLABELLED="$(jq -r '.[] | select([.labels[].name] | (index("major") or index("minor") or index("patch")) | not)
  | "#\(.number) \(.title)"' <<<"$PRS_JSON")"
if [[ -n "$UNLABELLED" ]]; then
  while IFS= read -r line; do
    echo "::warning::No major/minor/patch label, counted as patch: $line" >&2
  done <<<"$UNLABELLED"
fi

if [[ -z "$PREV_TAG" ]]; then
  # First release: take the version already in Info.plist rather than bumping it.
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist" 2>/dev/null \
    || sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/Support/Info.plist")"
  BUMP="initial"
else
  [[ "$PR_COUNT" -gt 0 ]] || { echo "::error::No PRs merged into $BASE_BRANCH since $PREV_TAG — nothing to release" >&2; exit 1; }
  BUMP="$OVERRIDE"; [[ "$BUMP" == "auto" ]] && BUMP="$(highest_label)"
  IFS=. read -r MAJOR MINOR PATCH <<<"${PREV_TAG#v}"
  case "$BUMP" in
    major) VERSION="$((MAJOR + 1)).0.0" ;;
    minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  esac
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Computed version '$VERSION' is not semver" >&2; exit 1; }
TAG="v$VERSION"
[[ -n "${INCLUDE_PR:-}" ]] && TAG="v$VERSION-pr.$INCLUDE_PR.${BUILD_NUMBER:?BUILD_NUMBER is needed with INCLUDE_PR}"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "::error::Tag $TAG already exists" >&2; exit 1
fi

OUT="version=$VERSION
tag=$TAG
previous_tag=$PREV_TAG
bump=$BUMP
prs=$PR_COUNT"
echo "$OUT"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$OUT" >> "$GITHUB_OUTPUT"
exit 0
