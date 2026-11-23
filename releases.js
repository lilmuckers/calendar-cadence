// Fills the download button (index.html) and the version grid (downloads.html).
// The release workflow writes releases.json next to this file after every
// release (scripts/site-downloads.py on main) and bakes the newest version into
// index.html, so the button is right even without JavaScript. If releases.json
// is missing, this falls back to the public GitHub Releases API.
(function () {
  "use strict";

  var REPO = "lilmuckers/calendar-cadence";
  var API = "https://api.github.com/repos/" + REPO + "/releases?per_page=100";
  var CACHE_KEY = "cadence-releases-v1";
  var CACHE_MS = 10 * 60 * 1000;

  function readCache() {
    try {
      var raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var hit = JSON.parse(raw);
      return Date.now() - hit.at < CACHE_MS ? hit.releases : null;
    } catch (e) { return null; }
  }

  function writeCache(releases) {
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), releases: releases })); } catch (e) {}
  }

  // Keep only what the page uses, so the cache stays small.
  function slim(r) {
    return {
      tag: r.tag_name,
      name: r.name,
      url: r.html_url,
      date: r.published_at,
      pre: r.prerelease,
      body: r.body || "",
      assets: (r.assets || []).map(function (a) {
        return { name: a.name, size: a.size, url: a.browser_download_url };
      })
    };
  }

  function fromSite() {
    return fetch("releases.json", { cache: "no-cache" }).then(function (res) {
      if (!res.ok) throw new Error("releases.json: " + res.status);
      return res.json();
    }).then(function (list) {
      if (!Array.isArray(list)) throw new Error("releases.json isn't a list");
      return list;
    });
  }

  function fromGitHub() {
    return fetch(API, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (res) {
        if (!res.ok) throw new Error("GitHub said " + res.status);
        return res.json();
      })
      .then(function (list) {
        var releases = list
          .filter(function (r) { return !r.draft; })
          .map(slim)
          .sort(function (a, b) { return new Date(b.date) - new Date(a.date); });
        return releases;
      });
  }

  function loadReleases() {
    var cached = readCache();
    if (cached) return Promise.resolve(cached);
    return fromSite().catch(fromGitHub).then(function (releases) {
      writeCache(releases);
      return releases;
    });
  }

  // Prefer the versioned file (Cadence-1.2.3.dmg); the fixed-name Cadence.dmg is a copy.
  function asset(release, ext) {
    var matches = release.assets.filter(function (a) { return a.name.toLowerCase().endsWith(ext); });
    return matches.filter(function (a) { return /-\d/.test(a.name); })[0] || matches[0] || null;
  }

  function version(release) { return release.tag.replace(/^v/, ""); }

  function size(bytes) {
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + " MB";
    return Math.max(1, Math.round(bytes / 1024)) + " KB";
  }

  function date(iso) {
    return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // Which build a "### 🖥️ Mac app" style section heading belongs to.
  function sectionTarget(heading) {
    var h = heading.toLowerCase();
    if (h.indexOf("mac") >= 0) return "mac";
    if (h.indexOf("iphone") >= 0 || h.indexOf("ios") >= 0) return "ios";
    if (h.indexOf("website") >= 0) return "website";
    if (h.indexOf("build") >= 0 || h.indexOf("ci") >= 0) return "ci";
    if (h.indexOf("docs") >= 0) return "docs";
    return "other";
  }

  // One build's bullet points from the release notes, dropping the
  // "by @someone in https://…/pull/12" tail. Notes split by build (a ### per
  // build, #### per kind) only give that build's section; older notes give
  // every bullet. Keep in step with changes() in scripts/site-downloads.py.
  function changes(body, target) {
    var lines = body.split(/\r?\n/);
    var byBuild = lines.some(function (line) { return /^\s*#### /.test(line); });
    var section = null;
    return lines
      .filter(function (line) {
        var heading = /^\s*### (.*)$/.exec(line);
        if (byBuild && heading) { section = sectionTarget(heading[1]); return false; }
        if (!/^\s*[*-]\s+/.test(line)) return false;
        return !byBuild || section === target;
      })
      .map(function (line) {
        return line.replace(/^\s*[*-]\s+/, "")
          .replace(/\s+by @\S+(\s+in\s+\S+)?\s*$/, "")
          .replace(/\*\*/g, "")
          .trim();
      })
      .filter(Boolean);
  }

  function setText(root, sel, text) {
    root.querySelectorAll(sel).forEach(function (el) { el.textContent = text; });
  }

  // ---- Download button on the home page ----
  function fillButton(card, releases) {
    var latest = releases.filter(function (r) { return !r.pre && asset(r, ".dmg"); })[0];
    if (!latest) return;
    var dmg = asset(latest, ".dmg");
    var zip = asset(latest, ".zip");
    card.querySelector("[data-dl-primary]").href = dmg.url;
    setText(card, "[data-dl-version]", "Version " + version(latest));
    setText(card, "[data-dl-size]", size(dmg.size) + " · .dmg");
    setText(card, "[data-dl-date]", "Released " + date(latest.date));
    var zipLink = card.querySelector("[data-dl-zip]");
    if (zipLink && zip) { zipLink.href = zip.url; zipLink.textContent = ".zip (" + size(zip.size) + ")"; }
    var notes = card.querySelector("[data-dl-notes]");
    if (notes) notes.href = latest.url;
    card.classList.add("is-loaded");
  }

  // ---- Version grid on the downloads page ----
  function fileButton(a, label, primary) {
    if (!a) return "";
    return '<a class="rel-file' + (primary ? " primary" : "") + '" href="' + esc(a.url) + '">' +
      '<span>' + esc(label) + '</span><small>' + esc(size(a.size)) + "</small></a>";
  }

  function card(release, isLatest) {
    // This is the Mac app's download history, so only the Mac app's changes.
    var items = changes(release.body, "mac");
    var shown = items.slice(0, isLatest ? 8 : 4);
    var more = items.length - shown.length;
    var sums = release.assets.filter(function (a) { return /sha256/i.test(a.name); })[0];
    var tags = (isLatest ? '<span class="rel-tag latest">Latest</span>' : "") +
      (release.pre ? '<span class="rel-tag pre">Pre-release</span>' : "");
    return '<article class="rel-card' + (isLatest ? " latest" : "") + '">' +
      '<header><h2>' + esc(version(release)) + "</h2>" + tags + "</header>" +
      '<p class="rel-date"><time datetime="' + esc(release.date) + '">' + esc(date(release.date)) + "</time></p>" +
      (shown.length
        ? '<ul class="rel-changes">' + shown.map(function (c) { return "<li>" + esc(c) + "</li>"; }).join("") +
          (more > 0 ? '<li class="more"><a href="' + esc(release.url) + '">+ ' + more + " more</a></li>" : "") + "</ul>"
        : '<p class="rel-empty">Behind-the-scenes changes only.</p>') +
      '<div class="rel-files">' +
        fileButton(asset(release, ".dmg"), "Download .dmg", true) +
        fileButton(asset(release, ".zip"), ".zip", false) +
      "</div>" +
      '<p class="rel-links"><a href="' + esc(release.url) + '">Release notes</a>' +
        (sums ? ' · <a href="' + esc(sums.url) + '">SHA-256 checksums</a>' : "") + "</p>" +
      "</article>";
  }

  function fillGrid(grid, releases) {
    var withFiles = releases.filter(function (r) { return asset(r, ".dmg") || asset(r, ".zip"); });
    if (!withFiles.length) throw new Error("no releases yet");
    var latestStable = withFiles.filter(function (r) { return !r.pre; })[0] || withFiles[0];
    var ordered = [latestStable].concat(withFiles.filter(function (r) { return r !== latestStable; }));
    grid.innerHTML = ordered.map(function (r, i) { return card(r, i === 0); }).join("");
    grid.setAttribute("aria-busy", "false");
    var count = document.querySelector("[data-rel-count]");
    if (count) count.textContent = withFiles.length === 1 ? "1 release" : withFiles.length + " releases";
  }

  function fail(grid) {
    if (!grid) return;
    grid.setAttribute("aria-busy", "false");
    grid.innerHTML = '<div class="rel-error"><p>Couldn’t load the version list from GitHub just now.</p>' +
      '<p><a class="cta" href="https://github.com/' + REPO + '/releases">See every release on GitHub</a></p></div>';
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.querySelector("[data-download-card]");
    var grid = document.querySelector("[data-release-grid]");
    if (!button && !grid) return;
    loadReleases()
      .then(function (releases) {
        if (button) fillButton(button, releases);
        if (grid) fillGrid(grid, releases);
      })
      .catch(function () { fail(grid); });
  });
})();
