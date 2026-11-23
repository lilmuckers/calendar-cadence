#!/usr/bin/env python3
"""Bring the website's download links up to date with the GitHub releases.

Usage: scripts/site-downloads.py <site-dir> [--releases-file releases.json]

<site-dir> is a checkout of the gh-pages branch. The script:
  - writes <site-dir>/releases.json: every published release, newest first, in the shape releases.js
    reads (the downloads page and the home page load it before trying the GitHub API);
  - rewrites the download card in <site-dir>/index.html so, even before any JavaScript runs, it links to
    the newest stable DMG and shows its version, size and date;
  - renders every version into <site-dir>/downloads.html, between the <!-- releases:start --> and
    <!-- releases:end --> markers, with the same markup releases.js draws (it redraws the same list).

Releases come from `gh api` (needs GH_TOKEN or a logged-in gh, and GH_REPO or a git remote), or from
--releases-file (a saved API response) for testing. Prints whether anything changed.
"""
import argparse
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def fetch_releases(repo):
    out = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"],
        check=True, capture_output=True, text=True).stdout
    return [r for page in json.loads(out) for r in page]


def slim(r):
    """The fields releases.js uses (keep in step with slim() there)."""
    return {
        "tag": r["tag_name"],
        "name": r.get("name") or r["tag_name"],
        "url": r["html_url"],
        "date": r.get("published_at") or r.get("created_at"),
        "pre": bool(r.get("prerelease")),
        "body": r.get("body") or "",
        "assets": [{"name": a["name"], "size": a["size"], "url": a["browser_download_url"]}
                   for a in r.get("assets") or []],
    }


def asset(release, ext):
    """Prefer the versioned file (Cadence-1.2.3.dmg); the fixed-name Cadence.dmg is a copy."""
    matches = [a for a in release["assets"] if a["name"].lower().endswith(ext)]
    versioned = [a for a in matches if re.search(r"-\d", a["name"])]
    return (versioned or matches or [None])[0]


def size(n):
    """Same rounding as releases.js."""
    if n >= 1048576:
        return f"{n / 1048576:.1f} MB"
    return f"{max(1, round(n / 1024))} KB"


def released(iso):
    d = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return f"Released {d.day} {d:%b %Y}"


def set_text(page, attr, text):
    """Replace the contents of the element carrying `attr` (e.g. data-dl-version)."""
    pattern = re.compile(r"(<(\w+)\b[^>]*\b" + re.escape(attr) + r"\b[^>]*>)(.*?)(</\2>)", re.S)
    page, n = pattern.subn(lambda m: m.group(1) + html.escape(text, quote=False) + m.group(4), page, count=1)
    if n != 1:
        raise SystemExit(f"no element with {attr}")
    return page


def set_href(page, attr, url):
    pattern = re.compile(r"(<a\b[^>]*\b" + re.escape(attr) + r"\b[^>]*\bhref=\")[^\"]*(\")")
    page, n = pattern.subn(lambda m: m.group(1) + html.escape(url) + m.group(2), page, count=1)
    if n != 1:
        raise SystemExit(f"no link with {attr}")
    return page


def update_index(page, releases):
    latest = next((r for r in releases if not r["pre"] and asset(r, ".dmg")), None)
    if latest is None:
        print("No stable release with a DMG yet; leaving the home page's download card alone.")
        return page
    dmg, zip_ = asset(latest, ".dmg"), asset(latest, ".zip")
    page = set_href(page, "data-dl-primary", dmg["url"])
    page = set_text(page, "data-dl-version", "Version " + latest["tag"].lstrip("v"))
    page = set_text(page, "data-dl-size", size(dmg["size"]) + " · .dmg")
    page = set_text(page, "data-dl-date", released(latest["date"]))
    if zip_:
        page = set_href(page, "data-dl-zip", zip_["url"])
        page = set_text(page, "data-dl-zip", f".zip ({size(zip_['size'])})")
    page = set_href(page, "data-dl-notes", latest["url"])
    print(f"Home page: {latest['tag']}, {dmg['name']} ({size(dmg['size'])})")
    return page


def esc(s):
    return html.escape(str(s), quote=True)


def changes(body):
    """The bullet points of the generated release notes, without the "by @someone in …" tail."""
    out = []
    for line in body.splitlines():
        if not re.match(r"^\s*[*-]\s+", line):
            continue
        line = re.sub(r"^\s*[*-]\s+", "", line)
        line = re.sub(r"\s+by @\S+(\s+in\s+\S+)?\s*$", "", line).replace("**", "").strip()
        if line:
            out.append(line)
    return out


def short_date(iso):
    d = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return f"{d.day} {d:%b %Y}"


def file_button(a, label, primary):
    if not a:
        return ""
    return (f'<a class="rel-file{" primary" if primary else ""}" href="{esc(a["url"])}">'
            f'<span>{esc(label)}</span><small>{esc(size(a["size"]))}</small></a>')


def card(r, is_latest):
    """Keep in step with card() in releases.js."""
    items = changes(r["body"])
    shown = items[:8 if is_latest else 4]
    more = len(items) - len(shown)
    sums = next((a for a in r["assets"] if re.search("sha256", a["name"], re.I)), None)
    tags = ('<span class="rel-tag latest">Latest</span>' if is_latest else "") + \
           ('<span class="rel-tag pre">Pre-release</span>' if r["pre"] else "")
    if shown:
        body = ('<ul class="rel-changes">' + "".join(f"<li>{esc(c)}</li>" for c in shown) +
                (f'<li class="more"><a href="{esc(r["url"])}">+ {more} more</a></li>' if more > 0 else "") + "</ul>")
    else:
        body = '<p class="rel-empty">Maintenance release.</p>'
    return (f'<article class="rel-card{" latest" if is_latest else ""}">'
            f'<header><h2>{esc(r["tag"].lstrip("v"))}</h2>{tags}</header>'
            f'<p class="rel-date"><time datetime="{esc(r["date"])}">{esc(short_date(r["date"]))}</time></p>'
            f'{body}<div class="rel-files">'
            f'{file_button(asset(r, ".dmg"), "Download .dmg", True)}{file_button(asset(r, ".zip"), ".zip", False)}'
            f'</div><p class="rel-links"><a href="{esc(r["url"])}">Release notes</a>'
            + (f' · <a href="{esc(sums["url"])}">SHA-256 checksums</a>' if sums else "") + "</p></article>")


def update_downloads(page, releases):
    with_files = [r for r in releases if asset(r, ".dmg") or asset(r, ".zip")]
    if not with_files:
        print("No releases with files yet; leaving the downloads page alone.")
        return page
    latest = next((r for r in with_files if not r["pre"]), with_files[0])
    ordered = [latest] + [r for r in with_files if r is not latest]
    cards = "\n".join("      " + card(r, i == 0) for i, r in enumerate(ordered))
    page, n = re.subn(r"(<!-- releases:start -->\n).*?(\n\s*<!-- releases:end -->)",
                      lambda m: m.group(1) + cards + m.group(2), page, count=1, flags=re.S)
    if n != 1:
        raise SystemExit("downloads.html: no <!-- releases:start --> … <!-- releases:end --> markers")
    page = re.sub(r'(<div class="rel-grid" data-release-grid[^>]*?)\s+aria-busy="true"', r'\1 aria-busy="false"', page)
    count = "1 release" if len(with_files) == 1 else f"{len(with_files)} releases"
    page = set_text(page, "data-rel-count", count)
    print(f"Downloads page: {count}")
    return page


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("site", type=Path)
    ap.add_argument("--releases-file", type=Path)
    args = ap.parse_args()

    if args.releases_file:
        raw = json.loads(args.releases_file.read_text())
    else:
        repo = os.environ.get("GH_REPO") or subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            check=True, capture_output=True, text=True).stdout.strip()
        raw = fetch_releases(repo)

    releases = sorted((slim(r) for r in raw if not r.get("draft")), key=lambda r: r["date"], reverse=True)

    changed = False
    data = args.site / "releases.json"
    text = json.dumps(releases, ensure_ascii=False, indent=1) + "\n"
    if not data.exists() or data.read_text() != text:
        data.write_text(text)
        changed = True
    print(f"releases.json: {len(releases)} releases")

    index = args.site / "index.html"
    page = index.read_text()
    new = update_index(page, releases)
    if new != page:
        index.write_text(new)
        changed = True

    downloads = args.site / "downloads.html"
    if downloads.exists():
        page = downloads.read_text()
        new = update_downloads(page, releases)
        if new != page:
            downloads.write_text(new)
            changed = True

    print("Changed." if changed else "Already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
