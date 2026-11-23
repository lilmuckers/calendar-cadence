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

    /// What changed between two versions: every installable release after `old` up to and including
    /// `new`, newest first.
    public static func changelog(_ releases: [GitHubRelease], from old: SemVer?, to new: SemVer) -> [GitHubRelease] {
        installable(releases)
            .filter { r in let v = r.version!; return v <= new && (old.map { v > $0 } ?? (v == new)) }
            .sorted { $0.version! > $1.version! }
    }
}
