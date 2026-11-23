#!/usr/bin/env python3
"""The changelog for a release: merged PRs grouped by which build they change, then by release label.

Usage:
  scripts/changelog.py <tag> [<previous-tag>] [--target-ref REF] [--only mac|ios|…] [--format markdown|text]
  scripts/changelog.py --rewrite <tag> [<previous-tag>]      # replace the changelog in a published release

A PR belongs to a release when its merge commit is in <previous-tag>..REF (REF defaults to <tag> if it
exists, else HEAD). Target labels put it under a build (a PR with two lands in both); major / minor / patch
put it under a kind. skip-changelog and bot PRs are left out. Needs git history with tags and gh
authenticated (GH_TOKEN in CI), with GH_REPO or a git remote.

markdown (default) is the release-notes section: every build, as below. The parsers in
Sources/CadenceCore/Updates.swift, scripts/site-downloads.py and the site's releases.js read it back:
`###` headings are builds and `####` headings kinds, so keep the shape.

    ## What's Changed

    ### 🖥️ Mac app
    #### ✨ New features
    * Title by @someone in https://github.com/o/r/pull/12

    **Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.1.0

text is plain bullets for one build (--only), for TestFlight's "What to Test" and the App Store's
"What's New".
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Order is the order in the notes. Keep the headings in step with ReleaseTarget in Updates.swift.
TARGETS = [
    ("mac", "🖥️ Mac app"),
    ("ios", "📱 iPhone app"),
    ("website", "🌐 Website"),
    ("ci", "⚙️ Build and release"),
    ("docs", "📝 Docs"),
]
OTHER = ("other", "📦 Other")
KINDS = [
    ("major", "💥 Breaking changes"),
    ("minor", "✨ New features"),
    ("patch", "🐛 Fixes and improvements"),
    (None, "📦 Other changes"),
]


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, cwd=ROOT).stdout.strip()


def repo():
    return os.environ.get("GH_REPO") or run("gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")


def tag_exists(tag):
    return subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"],
                          cwd=ROOT, capture_output=True).returncode == 0


def previous_tag(tag):
    """The release tag before `tag` (by version), or None for the first release."""
    tags = [t for t in run("git", "tag", "--list", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname").splitlines()
            if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
    key = lambda t: tuple(int(x) for x in t[1:].split("."))
    older = [t for t in tags if key(t) < key(tag)] if re.fullmatch(r"v\d+\.\d+\.\d+", tag) else tags
    return older[0] if older else None


def merged_prs(repo_name):
    out = run("gh", "pr", "list", "--repo", repo_name, "--state", "merged", "--base", "main", "--limit", "1000",
              "--json", "number,title,author,labels,mergeCommit,url")
    return json.loads(out)


def in_range(prs, prev, ref):
    shas = set(run("git", "rev-list", f"{prev}..{ref}" if prev else ref).splitlines())
    picked = [p for p in prs if (p.get("mergeCommit") or {}).get("oid") in shas]
    return sorted(picked, key=lambda p: p["number"])


def labels(pr):
    return {l["name"] for l in pr["labels"]}


def included(pr):
    login = (pr.get("author") or {}).get("login", "")
    bot = (pr.get("author") or {}).get("is_bot") or login.endswith("[bot]") or login.startswith("app/") \
        or "dependabot" in login
    return "skip-changelog" not in labels(pr) and not bot


def targets_of(pr):
    t = [key for key, _ in TARGETS if key in labels(pr)]
    return t or [OTHER[0]]


def kind_of(pr):
    for key, heading in KINDS:
        if key is None or key in labels(pr):
            return heading


def grouped(prs):
    """{target key: {kind heading: [pr, …]}}, in note order."""
    out = {}
    for key, _ in TARGETS + [OTHER]:
        mine = [p for p in prs if key in targets_of(p)]
        if mine:
            out[key] = {h: [p for p in mine if kind_of(p) == h] for _, h in KINDS}
            out[key] = {h: ps for h, ps in out[key].items() if ps}
    return out


def line(pr):
    login = (pr.get("author") or {}).get("login", "")
    return f"* {pr['title']} by @{login} in {pr['url']}" if login else f"* {pr['title']} in {pr['url']}"


def markdown(prs, repo_name, tag, prev):
    headings = dict(TARGETS + [OTHER])
    parts = ["## What's Changed", ""]
    groups = grouped(prs)
    if not groups:
        parts += ["Behind-the-scenes changes only.", ""]
    for target, kinds in groups.items():
        parts.append(f"### {headings[target]}")
        for heading, ps in kinds.items():
            parts.append(f"#### {heading}")
            parts += [line(p) for p in ps]
        parts.append("")
    compare = f"compare/{prev}...{tag}" if prev else f"commits/{tag}"
    parts.append(f"**Full Changelog**: https://github.com/{repo_name}/{compare}")
    return "\n".join(parts) + "\n"


def text(prs, target):
    """Plain bullets for one build, biggest kind first. Empty if nothing changed there."""
    kinds = grouped(prs).get(target, {})
    return "\n".join(f"• {p['title']}" for ps in kinds.values() for p in ps)


# A release body's changelog: from GitHub's generated-notes comment (if any) or "## What's Changed"
# through the "**Full Changelog**" line.
CHANGELOG_RE = re.compile(
    r"(?:<!-- Release notes generated[^\n]*-->\n+)?## What's Changed\n.*?\*\*Full Changelog\*\*:[^\n]*\n?", re.S)


def rewrite(repo_name, tag, new_section):
    body = run("gh", "release", "view", tag, "--repo", repo_name, "--json", "body", "-q", ".body")
    new_body, n = CHANGELOG_RE.subn(lambda _: new_section, body, count=1)
    if n != 1:
        raise SystemExit(f"{tag}: couldn't find the changelog section in the release body")
    if new_body.strip() == body.strip():
        print(f"{tag}: already up to date")
        return
    subprocess.run(["gh", "release", "edit", tag, "--repo", repo_name, "--notes-file", "-"],
                   input=new_body, text=True, check=True, cwd=ROOT, capture_output=True)
    print(f"{tag}: changelog rewritten")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tag")
    ap.add_argument("previous", nargs="?", help="previous release tag (default: the one before <tag>)")
    ap.add_argument("--target-ref", help="last commit of the release (default: <tag> if it exists, else HEAD)")
    ap.add_argument("--only", choices=[k for k, _ in TARGETS] + [OTHER[0]], help="one build (text format)")
    ap.add_argument("--format", choices=["markdown", "text"], default="markdown")
    ap.add_argument("--rewrite", action="store_true", help="replace the changelog in the published release <tag>")
    ap.add_argument("--prs-file", type=Path, help="saved `gh pr list --json …` output, for testing")
    args = ap.parse_args()

    prev = args.previous if args.previous is not None else previous_tag(args.tag)
    prev = prev or None
    ref = args.target_ref or (args.tag if tag_exists(args.tag) else "HEAD")
    repo_name = repo()
    prs = json.loads(args.prs_file.read_text()) if args.prs_file else merged_prs(repo_name)
    prs = [p for p in in_range(prs, prev, ref) if included(p)]

    if args.format == "text":
        if not args.only:
            raise SystemExit("--format text needs --only <build>")
        print(text(prs, args.only))
        return 0
    section = markdown(prs, repo_name, args.tag, prev)
    if args.rewrite:
        rewrite(repo_name, args.tag, section)
    else:
        sys.stdout.write(section)
    return 0


if __name__ == "__main__":
    sys.exit(main())
