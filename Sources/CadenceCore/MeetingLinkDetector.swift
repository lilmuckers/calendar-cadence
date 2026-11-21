import Foundation

public enum MeetingService: String, Codable, CaseIterable, Sendable {
    case zoom, googleMeet, teams, webex, goToMeeting, whereby, jitsi, chime, slack
    case blueJeans, skype, discord, faceTime, around, tuple, ringCentral, other

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .goToMeeting: "GoTo Meeting"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi"
        case .chime: "Amazon Chime"
        case .slack: "Slack Huddle"
        case .blueJeans: "BlueJeans"
        case .skype: "Skype"
        case .discord: "Discord"
        case .faceTime: "FaceTime"
        case .around: "Around"
        case .tuple: "Tuple"
        case .ringCentral: "RingCentral"
        case .other: "Link"
        }
    }

    /// SF Symbol used next to the Join button.
    public var symbol: String {
        switch self {
        case .zoom, .webex, .goToMeeting, .blueJeans, .ringCentral: "video.fill"
        case .googleMeet: "video.badge.waveform.fill"
        case .teams: "person.3.fill"
        case .faceTime: "video.circle.fill"
        case .slack, .discord: "headphones"
        case .skype, .chime: "phone.fill"
        case .whereby, .jitsi, .around, .tuple: "rectangle.inset.filled.and.person.filled"
        case .other: "link"
        }
    }
}

public struct MeetingLink: Codable, Hashable, Sendable {
    public var service: MeetingService
    public var url: URL

    public init(service: MeetingService, url: URL) {
        self.service = service
        self.url = url
    }

    /// Deep link that opens the native app directly (skipping the browser bounce page), if one exists.
    public var nativeURL: URL? {
        switch service {
        case .zoom:
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            if comps.scheme == "zoommtg" { return url }
            let path = comps.path.split(separator: "/")
            guard path.count >= 2, ["j", "w", "s"].contains(path[0]) else { return nil }
            var out = URLComponents()
            out.scheme = "zoommtg"
            out.host = comps.host ?? "zoom.us"
            out.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(path[1]))]
            if let pwd = comps.queryItems?.first(where: { $0.name == "pwd" })?.value {
                items.append(URLQueryItem(name: "pwd", value: pwd))
            }
            out.queryItems = items
            return out.url
        case .teams:
            let s = url.absoluteString
            guard let range = s.range(of: "://") else { return nil }
            return URL(string: "msteams:" + s[range.upperBound...].drop(while: { $0 != "/" }))
        default:
            return nil
        }
    }
}

/// Finds a joinable online-meeting link in an event's URL, location or notes.
public enum MeetingLinkDetector {
    private struct Rule {
        let service: MeetingService
        let regex: NSRegularExpression
    }

    private static func rule(_ service: MeetingService, _ pattern: String) -> Rule {
        // Patterns are static and covered by tests, so a failure here is a programmer error.
        Rule(service: service, regex: try! NSRegularExpression(pattern: "^" + pattern, options: [.caseInsensitive]))
    }

    private static let rules: [Rule] = [
        rule(.zoom, #"zoommtg://"#),
        rule(.zoom, #"https?://([a-z0-9-]+\.)?zoom(gov)?\.(us|com)/(j|my|w|s|wc/join|meeting/register)/"#),
        rule(.googleMeet, #"https?://meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/)"#),
        rule(.teams, #"https?://teams\.microsoft\.com/(l/meetup-join|meet)/"#),
        rule(.teams, #"https?://teams\.live\.com/meet/"#),
        rule(.teams, #"msteams:"#),
        rule(.webex, #"https?://([a-z0-9-]+\.)+webex\.com/([a-z0-9-]+/)?(meet|join|j\.php|wbxmjs|webappng)"#),
        rule(.goToMeeting, #"https?://((global|www|app)\.)?(gotomeet(ing)?\.(com|me)|goto\.com/meeting|meet\.goto\.com)/"#),
        rule(.whereby, #"https?://(www\.)?whereby\.com/[^/]+"#),
        rule(.jitsi, #"https?://meet\.jit\.si/[^/]+"#),
        rule(.chime, #"https?://(app\.)?chime\.aws/[0-9]+"#),
        rule(.slack, #"https?://app\.slack\.com/huddle/"#),
        rule(.blueJeans, #"https?://([a-z0-9-]+\.)?bluejeans\.com/[0-9a-z]"#),
        rule(.skype, #"https?://join\.skype\.com/"#),
        rule(.discord, #"https?://(www\.)?(discord\.gg|discord(app)?\.com/(channels|invite|events))/"#),
        rule(.faceTime, #"https?://facetime\.apple\.com/join"#),
        rule(.around, #"https?://(meet\.)?around\.co/"#),
        rule(.tuple, #"https?://tuple\.app/c/"#),
        rule(.ringCentral, #"https?://(meetings|v)\.ringcentral\.com/"#),
    ]

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?:https?|zoommtg|msteams)://?[^\s<>"'\]\)\}|]+"#,
        options: [.caseInsensitive]
    )

    /// Checks sources in priority order: explicit URL field, then location, then notes/body.
    public static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        let sources = [url?.absoluteString, location, notes].compactMap { $0 }
        for text in sources {
            if let link = firstMeetingLink(in: text) { return link }
        }
        // Fallback: a bare URL in the URL or location field is very likely the join link.
        for text in [url?.absoluteString, location].compactMap({ $0 }) {
            if let first = extractURLs(from: text).first(where: { $0.scheme?.hasPrefix("http") == true }) {
                return MeetingLink(service: .other, url: first)
            }
        }
        return nil
    }

    /// `link` checked the way calendar links are: a known meeting service's link (with its service
    /// worked out again here), else a plain web link. Anything else (`file:`, other apps' schemes) is
    /// nil. For links that arrive from another device rather than from a calendar.
    public static func trusted(_ link: MeetingLink) -> MeetingLink? {
        let url = link.url
        let s = url.absoluteString
        let range = NSRange(s.startIndex..., in: s)
        if let rule = rules.first(where: { $0.regex.firstMatch(in: s, range: range) != nil }) {
            return MeetingLink(service: rule.service, url: url)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return MeetingLink(service: .other, url: url)
    }

    public static func firstMeetingLink(in text: String) -> MeetingLink? {
        for candidate in extractURLs(from: text) {
            let s = candidate.absoluteString
            let range = NSRange(s.startIndex..., in: s)
            if let rule = rules.first(where: { $0.regex.firstMatch(in: s, range: range) != nil }) {
                return MeetingLink(service: rule.service, url: candidate)
            }
        }
        return nil
    }

    /// All URLs in the text, HTML entities decoded and redirect wrappers (Outlook SafeLinks, Google) removed.
    public static func extractURLs(from text: String) -> [URL] {
        let decoded = decodeEntities(text)
        let range = NSRange(decoded.startIndex..., in: decoded)
        return urlRegex.matches(in: decoded, range: range).compactMap { match in
            guard let r = Range(match.range, in: decoded) else { return nil }
            var s = String(decoded[r])
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            guard let url = URL(string: s) else { return nil }
            return unwrap(url)
        }
    }

    /// Strips redirect wrappers, repeatedly, since links are sometimes double-wrapped.
    public static func unwrap(_ url: URL) -> URL {
        var current = url
        for _ in 0..<3 {
            guard let comps = URLComponents(url: current, resolvingAgainstBaseURL: false),
                  let host = comps.host?.lowercased() else { break }
            let key: String?
            if host.hasSuffix("safelinks.protection.outlook.com") {
                key = "url"
            } else if (host == "www.google.com" || host == "google.com") && comps.path == "/url" {
                key = "q"
            } else if host.hasSuffix("urldefense.com") || host.hasSuffix("urldefense.proofpoint.com") {
                key = "u"
            } else {
                key = nil
            }
            guard let key,
                  let inner = comps.queryItems?.first(where: { $0.name == key })?.value,
                  let next = URL(string: inner) else { break }
            current = next
        }
        return current
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Plain-text rendering of an HTML-ish invite body for display.
    public static func plainText(_ notes: String) -> String {
        var s = notes.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s).replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
