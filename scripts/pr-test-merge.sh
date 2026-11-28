#!/usr/bin/env bash
# Merge a PR's head into main locally, for a test build of that PR. Nothing is pushed: the PR stays open
# and main is untouched.
#
# Usage: scripts/pr-test-merge.sh <pr-number> <main-sha> <pr-head-sha> <date>
#   <date> is used as the merge's author and committer date, so every job that runs this with the same
#   arguments makes the same commit (same SHA), and the release tag points at exactly what was built.
# Needs a checkout with full history (fetch-depth: 0). Leaves HEAD detached at the merge and prints its SHA.
# Fails, listing the conflicting files, when the PR doesn't merge cleanly into main.
set -euo pipefail

PR="$1" BASE="$2" HEAD="$3" DATE="$4"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "::error::'$PR' isn't a PR number" >&2; exit 1; }

# The PR's head lives under refs/pull/<n>/head (also for PRs from forks). If the PR has moved on since
# the run started, fetch the pinned commit itself.
git fetch -q --no-tags origin "+refs/pull/$PR/head:refs/remotes/pr/$PR" "$BASE" >&2
git cat-file -e "$HEAD^{commit}" 2>/dev/null || git fetch -q --no-tags origin "$HEAD" >&2

git checkout -q --detach "$BASE"
export GIT_AUTHOR_NAME="github-actions[bot]" GIT_COMMITTER_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="$DATE" GIT_COMMITTER_DATE="$DATE"
if ! git merge -q --no-ff --no-edit -m "Test build of #$PR on main" "$HEAD" >&2; then
  echo "::error::PR #$PR conflicts with main. Resolve the conflicts on the PR, then run the release again." >&2
  git diff --name-only --diff-filter=U | sed 's/^/::error::Conflict: /' >&2
  git merge --abort || true
  exit 1
fi
git rev-parse HEAD
