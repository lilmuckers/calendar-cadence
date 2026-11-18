import Foundation

/// Browsers whose profiles Cadence can target. Safari isn't here on purpose: it has no supported way
/// to open a URL in a given profile, so links keep opening the normal way when it's the default.
public enum ProfileBrowser: String, Codable, CaseIterable, Sendable {
    case chrome, chromeBeta, chromeCanary, chromium, edge, brave, vivaldi, firefox

    public var bundleID: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .chromeBeta: "com.google.Chrome.beta"
        case .chromeCanary: "com.google.Chrome.canary"
        case .chromium: "org.chromium.Chromium"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .firefox: "org.mozilla.firefox"
        }
    }

    public var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .chromeBeta: "Chrome Beta"
        case .chromeCanary: "Chrome Canary"
        case .chromium: "Chromium"
        case .edge: "Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        case .firefox: "Firefox"
        }
    }

    public var isChromium: Bool { self != .firefox }

    /// Where the browser keeps its profile list, relative to ~/Library/Application Support.
    public var profileListPath: String {
        switch self {
        case .chrome: "Google/Chrome/Local State"
        case .chromeBeta: "Google/Chrome Beta/Local State"
        case .chromeCanary: "Google/Chrome Canary/Local State"
        case .chromium: "Chromium/Local State"
        case .edge: "Microsoft Edge/Local State"
        case .brave: "BraveSoftware/Brave-Browser/Local State"
        case .vivaldi: "Vivaldi/Local State"
        case .firefox: "Firefox/profiles.ini"
        }
    }

    public init?(bundleID: String) {
        guard let match = Self.allCases.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return nil }
        self = match
    }
}

/// One profile (or, for Firefox, a profile plus an optional container) a meeting link can open in.
public struct BrowserProfile: Codable, Hashable, Identifiable, Sendable {
    public var browser: ProfileBrowser
    /// Chromium: the profile directory name ("Profile 5"). Firefox: the profile folder's absolute path.
    public var directory: String
    public var name: String
    public var email: String?
    /// Firefox Multi-Account Container name (needs the "Open external links in a container" add-on).
    public var container: String?

    public init(browser: ProfileBrowser, directory: String, name: String, email: String? = nil, container: String? = nil) {
        self.browser = browser
        self.directory = directory
        self.name = name
        self.email = email
        self.container = container
    }

    public var id: String {
        var s = "\(browser.rawValue)/\(directory)"
        if let container { s += "#\(container)" }
        return s
    }

    /// "Client A", or "Work › Client A" for a container.
    public var title: String {
        guard let container else { return name }
        return "\(name) › \(container)"
    }

    /// Arguments for the browser executable. The URL is always one argv element; no shell is involved.
    public func launchArguments(for url: URL) -> [String] {
        if browser.isChromium {
            return ["--profile-directory=\(directory)", url.absoluteString]
        }
        var target = url.absoluteString
        if let container {
            // The add-on reads name= and url= as query values, so both are fully percent-encoded.
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            if let name = container.addingPercentEncoding(withAllowedCharacters: unreserved),
               let link = url.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) {
                target = "ext+container:name=\(name)&url=\(link)"
            }
        }
        return ["--profile", directory, "-new-tab", target]
    }
}

public enum BrowserProfiles {
    /// Parses a Chromium `Local State` file: `profile.info_cache.<dir>.{name,user_name}`.
    public static func parseChromium(localState data: Data, browser: ProfileBrowser) -> [BrowserProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { dir, value -> BrowserProfile? in
            guard let info = value as? [String: Any] else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return BrowserProfile(browser: browser, directory: dir, name: name, email: email)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Parses Firefox's `profiles.ini`. `base` is the folder that holds it (relative paths resolve against it).
    public static func parseFirefox(profilesINI text: String, base: URL) -> [BrowserProfile] {
        var sections: [(String, [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].1[key] = value
            }
        }
        return sections.compactMap { header, kv -> BrowserProfile? in
            guard header.hasPrefix("Profile"), let path = kv["Path"], !path.isEmpty else { return nil }
            let relative = kv["IsRelative"].map { $0 != "0" } ?? true
            let full = relative ? base.appendingPathComponent(path).path : path
            return BrowserProfile(browser: .firefox, directory: full, name: kv["Name"] ?? path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A rule matching the organizer's email domain (and its subdomains).
public struct DomainProfileRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var domain: String
    public var profileID: String

    public init(id: UUID = UUID(), domain: String, profileID: String) {
        self.id = id
        self.domain = domain
        self.profileID = profileID
    }
}

/// A Firefox container the user has added under one of their Firefox profiles.
public struct FirefoxContainer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var profileDirectory: String
    public var name: String

    public init(id: UUID = UUID(), profileDirectory: String, name: String) {
        self.id = id
        self.profileDirectory = profileDirectory
        self.name = name
    }
}

/// Which profile opens which meeting. Most specific wins: meeting → series → organizer domain → calendar → account.
public struct ProfileRules: Codable, Equatable, Sendable {
    public var meetings: [String: String] = [:]
    public var series: [String: String] = [:]
    public var domains: [DomainProfileRule] = []
    public var calendars: [String: String] = [:]
    /// Keyed by `CalendarInfo.sourceTitle`.
    public var accounts: [String: String] = [:]
    /// Services where an assigned profile opens instead of the native app.
    public var nativeOverride: Set<MeetingService> = [.teams]
    public var firefoxContainers: [FirefoxContainer] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProfileRules()
        meetings = (try? c.decodeIfPresent([String: String].self, forKey: .meetings)) ?? d.meetings
        series = (try? c.decodeIfPresent([String: String].self, forKey: .series)) ?? d.series
        domains = (try? c.decodeIfPresent([DomainProfileRule].self, forKey: .domains)) ?? d.domains
        calendars = (try? c.decodeIfPresent([String: String].self, forKey: .calendars)) ?? d.calendars
        accounts = (try? c.decodeIfPresent([String: String].self, forKey: .accounts)) ?? d.accounts
        nativeOverride = (try? c.decodeIfPresent(Set<MeetingService>.self, forKey: .nativeOverride)) ?? d.nativeOverride
        firefoxContainers = (try? c.decodeIfPresent([FirefoxContainer].self, forKey: .firefoxContainers)) ?? d.firefoxContainers
    }

    public var isEmpty: Bool {
        meetings.isEmpty && series.isEmpty && domains.isEmpty && calendars.isEmpty && accounts.isEmpty
    }
}

public struct ProfileChoice: Equatable, Sendable {
    public enum Source: String, Sendable { case meeting, series, domain, calendar, account }
    public var profile: BrowserProfile
    public var source: Source
    public var reason: String
}

/// Where a join goes.
public enum JoinRoute: Equatable, Sendable {
    case native(URL)
    case profile(BrowserProfile, URL)
    case defaultBrowser(URL)
}

public enum ProfileResolver {
    /// `profiles` should be the default browser's profiles only: a rule naming any other browser's
    /// profile finds nothing here and is skipped, so the link falls back to the default browser.
    public static func resolve(_ m: Meeting, rules: ProfileRules, profiles: [BrowserProfile]) -> ProfileChoice? {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func pick(_ id: String?, _ source: ProfileChoice.Source, _ reason: String) -> ProfileChoice? {
            guard let id, let p = byID[id] else { return nil }
            return ProfileChoice(profile: p, source: source, reason: reason)
        }
        if let c = pick(rules.meetings[m.id], .meeting, "Chosen for this meeting") { return c }
        if let c = pick(rules.series[m.seriesID], .series, "Chosen for this series") { return c }
        if let email = m.organizerEmail {
            for rule in rules.domains where domainMatches(email: email, domain: rule.domain) {
                if let c = pick(rule.profileID, .domain, "Organizer @\(normalized(rule.domain))") { return c }
            }
        }
        if let c = pick(rules.calendars[m.calendar.id], .calendar, "Calendar \(m.calendar.title)") { return c }
        if let c = pick(rules.accounts[m.calendar.sourceTitle], .account, "Account \(m.calendar.sourceTitle)") { return c }
        return nil
    }

    public static func route(for link: MeetingLink, choice: ProfileChoice?, rules: ProfileRules,
                             preferNative: Bool, nativeAvailable: (URL) -> Bool) -> JoinRoute {
        let profileWins = choice != nil && rules.nativeOverride.contains(link.service)
        if preferNative, !profileWins, let native = link.nativeURL, nativeAvailable(native) {
            return .native(native)
        }
        if let choice { return .profile(choice.profile, link.url) }
        return .defaultBrowser(link.url)
    }

    static func normalized(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        while d.hasPrefix(".") { d.removeFirst() }
        return d
    }

    /// `a@eu.client.example` matches `client.example`; `a@evil-client.example` does not.
    public static func domainMatches(email: String, domain: String) -> Bool {
        let rule = normalized(domain)
        guard !rule.isEmpty, let at = email.lastIndex(of: "@") else { return false }
        let host = email[email.index(after: at)...].lowercased()
        return host == rule || host.hasSuffix("." + rule)
    }

    /// A profile that looks like it belongs to this account (same email, then same domain).
    /// Only ever shown as a suggestion.
    public static func suggest(accountTitle: String, profiles: [BrowserProfile]) -> BrowserProfile? {
        let emails = accountTitle.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" })
            .map(String.init).filter { $0.contains("@") }
        guard let email = emails.first?.lowercased() else { return nil }
        if let p = profiles.first(where: { $0.email?.lowercased() == email && $0.container == nil }) { return p }
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...])
        return profiles.first { p in
            p.container == nil && (p.email.map { domainMatches(email: $0, domain: domain) } ?? false)
        }
    }
}
