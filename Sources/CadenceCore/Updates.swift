import Foundation

/// How Cadence keeps itself up to date from GitHub releases.
public enum UpdateMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Never look for updates.
    case off
    /// Look for updates and say when one is out, with a button to install it.
    case notify
    /// Download and install updates by themselves, at a quiet moment.
    case automatic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Don't check for updates"
        case .notify: "Tell me about updates"
        case .automatic: "Update automatically"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Cadence never contacts GitHub. You can still check by hand in Settings."
        case .notify: "Cadence checks GitHub a few times a day and lets you know when a new version is out. One click installs it."
        case .automatic: "New versions download and install in the background, and Cadence restarts when no meeting is about to start."
        }
    }

    public var symbol: String {
        switch self {
        case .off: "hand.raised"
        case .notify: "bell.badge"
        case .automatic: "arrow.triangle.2.circlepath"
        }
    }
}

/// A plain `major.minor.patch` version, as in the release tags (`v1.2.3`).
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2` (patch 0) and ignores a `-beta`/`+build` suffix.
    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.init(numbers[0]!, numbers[1]!, numbers.count == 3 ? numbers[2]! : 0)
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// The parts of GitHub's release JSON the updater uses.
public struct GitHubRelease: Codable, Equatable, Identifiable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public var name: String
        public var url: URL
        public var size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case url = "browser_download_url"
        }

        public init(name: String, url: URL, size: Int) {
            self.name = name; self.url = url; self.size = size
        }
    }

    public var tag: String
    public var name: String?
    public var body: String?
    public var page: URL
    public var publishedAt: Date?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tag = "tag_name"
        case page = "html_url"
        case publishedAt = "published_at"
    }

    public init(tag: String, name: String? = nil, body: String? = nil, page: URL, publishedAt: Date? = nil,
                draft: Bool = false, prerelease: Bool = false, assets: [Asset] = []) {
        self.tag = tag; self.name = name; self.body = body; self.page = page; self.publishedAt = publishedAt
        self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    public var id: String { tag }
    public var version: SemVer? { SemVer(tag) }

    /// Decodes the array GitHub returns from `/repos/{owner}/{repo}/releases`.
    public static func decodeList(_ data: Data) throws -> [GitHubRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}

/// How big a change is, from the release label on its pull request (see .github/release.yml).
public enum ChangeKind: Int, Comparable, CaseIterable, Sendable {
    case other, fix, feature, breaking

    public static func < (a: ChangeKind, b: ChangeKind) -> Bool { a.rawValue < b.rawValue }

    /// The category heading GitHub wrote, e.g. "### ✨ New features".
    init(heading: String) {
        let h = heading.lowercased()
        if h.contains("💥") || h.contains("breaking") { self = .breaking }
        else if h.contains("✨") || h.contains("feature") || h.contains("new") { self = .feature }
        else if h.contains("🐛") || h.contains("fix") { self = .fix }
        else { self = .other }
    }

    public var label: String {
        switch self {
        case .breaking: "Breaking"
        case .feature: "New"
        case .fix: "Fix"
        case .other: "Other"
        }
    }

    /// What a release whose biggest change is this kind is called.
    public var releaseLabel: String {
        switch self {
        case .breaking: "Major release"
        case .feature: "Feature release"
        case .fix, .other: "Bug-fix release"
        }
    }
}

/// Which build a change lands in, from the build labels on its pull request (scripts/changelog.py writes
/// one `###` section per build).
public enum ReleaseTarget: String, CaseIterable, Sendable {
    case mac, ios, website, ci, docs, other

    /// The section heading, e.g. "### 🖥️ Mac app". Keep in step with TARGETS in scripts/changelog.py.
    init?(heading: String) {
        let h = heading.lowercased()
        if h.contains("mac") { self = .mac }
        else if h.contains("iphone") || h.contains("ios") { self = .ios }
        else if h.contains("website") { self = .website }
        else if h.contains("build") || h.contains("ci") { self = .ci }
        else if h.contains("docs") { self = .docs }
        else if h.contains("other") { self = .other }
        else { return nil }
    }
}

/// One merged pull request in a release's notes.
public struct ReleaseChange: Equatable, Hashable, Sendable {
    public var title: String
    public var kind: ChangeKind
    public var pull: Int?
    /// The build section it was listed under; nil in notes from before they were split by build.
    public var target: ReleaseTarget?

    public init(title: String, kind: ChangeKind, pull: Int? = nil, target: ReleaseTarget? = nil) {
        self.title = title; self.kind = kind; self.pull = pull; self.target = target
    }
}

/// Picks releases and reads their assets and notes. No networking here, so it can be tested.
public enum UpdatePlanner {
    /// Published, final releases with a version tag. Pre-releases are the un-notarized builds.
    public static func installable(_ releases: [GitHubRelease]) -> [GitHubRelease] {
        releases.filter { !$0.draft && !$0.prerelease && $0.version != nil }
    }

    /// The newest release that is newer than `current`, if any.
    public static func newest(in releases: [GitHubRelease], newerThan current: SemVer) -> GitHubRelease? {
        installable(releases)
            .filter { $0.version! > current }
            .max { $0.version! < $1.version! }
    }

    /// The zipped app: `Cadence-X.Y.Z.zip`.
    public static func zipAsset(_ release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first { $0.name.hasPrefix("Cadence-") && $0.name.hasSuffix(".zip") }
    }

    public static func checksumsAsset(_ release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first { $0.name == "SHA256SUMS.txt" }
    }

    /// `shasum -a 256` output: `<hex>  <file>` per line → file name → lowercase hex digest.
    public static func parseChecksums(_ text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() } // binary-mode marker
            sums[file] = hash
        }
        return sums
    }

    /// A release body cut down to what changed: no title, date, signing note, HTML comments, install
    /// steps or checksums (see .github/RELEASE_NOTES_TEMPLATE.md). Pull request links become `#123`.
    public static func releaseNotes(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        while let open = text.range(of: "<!--"), let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let install = text.range(of: "\n## 📥") { text = String(text[..<install.lowerBound]) }
        if text.hasPrefix("## 📥") { text = "" }

        var lines: [String] = []
        var inAlert = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // GitHub alert blocks (> [!NOTE] …) carry the signing note.
            if line.hasPrefix("> [!") { inAlert = true; continue }
            if inAlert {
                if line.hasPrefix(">") { continue }
                inAlert = false
            }
            if line.hasPrefix("## Cadence ") || line.hasPrefix("# Cadence ") { continue }
            if line.hasPrefix("_Released ") && line.hasSuffix("_") { continue }
            if line == "## What's Changed" { continue }
            lines.append(shortenPullLinks(raw))
        }
        // Collapse runs of blank lines and trim the ends.
        var out: [String] = []
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, out.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
            out.append(line)
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// `… by @someone in https://github.com/o/r/pull/12` → `… ([#12](https://github.com/o/r/pull/12))`.
    static func shortenPullLinks(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #" by @[A-Za-z0-9-]+(?:\[bot\])? in (https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+))"#) else { return line }
        let ns = line as NSString
        return regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: " ([#$2]($1))")
    }

    /// The pull requests listed in a release's notes, biggest kind first (the notes' order within a kind).
    ///
    /// Notes split by build have a `###` heading per build and `####` headings per kind; pass `target` to
    /// keep only one build's changes (a PR listed under two builds then appears once). Older notes have
    /// only `###` kind headings: their changes have no target and are kept whatever `target` is.
    public static func changes(_ body: String, for target: ReleaseTarget? = nil) -> [ReleaseChange] {
        let notes = releaseNotes(body)
        let lines = notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let byBuild = lines.contains { $0.hasPrefix("#### ") }
        var kind = ChangeKind.other
        var section: ReleaseTarget?
        var changes: [ReleaseChange] = []
        let pullLink = try? NSRegularExpression(pattern: #"\s*\(\[#(\d+)\]\([^)]*\)\)\s*$"#)
        for line in lines {
            if line.hasPrefix("#") {
                if byBuild, line.hasPrefix("### ") {
                    section = ReleaseTarget(heading: String(line.dropFirst(4))) ?? .other
                    kind = .other
                } else {
                    kind = ChangeKind(heading: line)
                }
                continue
            }
            guard line.hasPrefix("* ") || line.hasPrefix("- ") else { continue }
            var title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var pull: Int?
            let ns = title as NSString
            if let m = pullLink?.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) {
                pull = Int(ns.substring(with: m.range(at: 1)))
                title = ns.replacingCharacters(in: m.range, with: "")
            }
            guard !title.isEmpty else { continue }
            if let target, let section, section != target { continue }
            changes.append(ReleaseChange(title: title, kind: kind, pull: pull, target: section))
        }
        // Stable sort: biggest first, keeping GitHub's order inside each kind.
        return changes.enumerated()
            .sorted { $0.element.kind != $1.element.kind ? $0.element.kind > $1.element.kind : $0.offset < $1.offset }
            .map(\.element)
    }

    /// What changed between two versions: every installable release after `old` up to and including
    /// `new`, newest first.
    public static func changelog(_ releases: [GitHubRelease], from old: SemVer?, to new: SemVer) -> [GitHubRelease] {
        installable(releases)
            .filter { r in let v = r.version!; return v <= new && (old.map { v > $0 } ?? (v == new)) }
            .sorted { $0.version! > $1.version! }
    }
}
