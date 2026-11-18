import Foundation

/// Why you're late, guessed from the meeting before this one.
public enum LateSituation: String, Codable, CaseIterable, Sendable {
    /// The previous meeting is still going (or you're still on a call).
    case overrun
    /// Back-to-back: the previous one ended right as this started and you're off the call.
    case breather
    /// Nothing before it: you're just late.
    case late
}

/// The "Running late" messages, editable in Settings. `{mins}` becomes "2 mins"; `{name}` the person
/// from your previous 1:1 (only used when `mentionName` is on).
public struct LateMessageSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var overrun = "Just wrapping up my previous meeting — there in {mins}!"
    public var overrunWithName = "Just wrapping up with {name} — there in {mins}!"
    public var breather = "Grabbing a quick breather between back-to-backs — there in {mins}!"
    public var late = "Running a few minutes late, sorry! Be there in {mins}."
    /// Extra messages of your own, offered alongside the suggestion.
    public var custom: [String] = []
    /// Name the person from a previous 1:1 ("wrapping up with Roy"). Off by default: it tells this meeting
    /// who you were just with.
    public var mentionName = false
    public var defaultMinutes = 2
    /// Domain → channel (and account) for meetings whose link doesn't decide.
    public var domainRules: [LateDomainRule] = []

    public static let minuteChoices = [2, 5, 10]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LateMessageSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        overrun = try c.decodeIfPresent(String.self, forKey: .overrun) ?? d.overrun
        overrunWithName = try c.decodeIfPresent(String.self, forKey: .overrunWithName) ?? d.overrunWithName
        breather = try c.decodeIfPresent(String.self, forKey: .breather) ?? d.breather
        late = try c.decodeIfPresent(String.self, forKey: .late) ?? d.late
        custom = try c.decodeIfPresent([String].self, forKey: .custom) ?? d.custom
        mentionName = try c.decodeIfPresent(Bool.self, forKey: .mentionName) ?? d.mentionName
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? d.defaultMinutes
        domainRules = (try? c.decodeIfPresent([LateDomainRule].self, forKey: .domainRules)) ?? d.domainRules
    }
}

/// The kinds of place a running-late message can go.
public enum LateChannelKind: String, Codable, CaseIterable, Sendable {
    case teams, googleChat, slack, email

    public var label: String {
        switch self {
        case .teams: "Teams"
        case .googleChat: "Google Chat"
        case .slack: "Slack"
        case .email: "Email"
        }
    }
}

/// "Meetings with people @domain go to this channel, from this account" — the fallback when the meeting
/// link doesn't decide (a Zoom call with a client who lives in Slack, say).
public struct LateDomainRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var domain: String
    public var channel: LateChannelKind
    /// The Cadence account to send from (Google/Microsoft account id, or Slack workspace id). nil = best guess.
    public var accountID: String?

    public init(id: String = UUID().uuidString, domain: String, channel: LateChannelKind, accountID: String? = nil) {
        self.id = id
        self.domain = domain
        self.channel = channel
        self.accountID = accountID
    }
}

/// An account Cadence can send from, as far as routing cares.
public struct MessagingAccount: Hashable, Sendable {
    public enum Kind: String, Sendable { case google, microsoft, slack }
    public var id: String
    public var kind: Kind
    /// Your address on it (nil for Slack).
    public var email: String?
    public var label: String
    /// Granted: mail / chat (Teams for Microsoft, Google Chat for Google, chat:write for Slack).
    public var canMail: Bool
    public var canChat: Bool
    public var slackTeam: String?

    public init(id: String, kind: Kind, email: String?, label: String, canMail: Bool, canChat: Bool, slackTeam: String? = nil) {
        self.id = id
        self.kind = kind
        self.email = email?.lowercased()
        self.label = label
        self.canMail = canMail
        self.canChat = canChat
        self.slackTeam = slackTeam
    }

    public var domain: String? { email?.split(separator: "@").last.map(String.init) }
}

/// Exactly where a message goes.
public enum LateTarget: Hashable, Sendable {
    /// The Teams meeting's own chat. `threadID` is in classic join links; short links need a Graph lookup.
    case teamsMeetingChat(threadID: String?, joinURL: URL)
    /// A Google Chat direct message (found, or set up if there isn't one yet).
    case googleDM(email: String)
    /// A Google Chat group conversation with these people.
    case googleGroup(emails: [String])
    case slackChannel(channel: String)
    /// A Slack DM with whoever has this address in the workspace.
    case slackDM(email: String)
    case email(to: [String])

    public var kind: LateChannelKind {
        switch self {
        case .teamsMeetingChat: .teams
        case .googleDM, .googleGroup: .googleChat
        case .slackChannel, .slackDM: .slack
        case .email: .email
        }
    }
}

/// One choice in the "Send via" menu.
public struct LateOption: Hashable, Identifiable, Sendable {
    public var target: LateTarget
    public var accountID: String
    /// "Teams meeting chat", "Google Chat → Sam", "Email to 5 people"…
    public var label: String
    /// Which of your accounts it's sent from.
    public var accountLabel: String
    /// Why it can't be used, known without asking the service (e.g. permission not granted). nil = try it.
    public var blocked: String?

    public var id: String { "\(accountID)|\(target)" }
}

public enum RunningLate {
    // MARK: Suggesting

    /// The meeting right before `meeting`: one that ended at most `gap` before it started, or is still running.
    public static func previous(to meeting: Meeting, in meetings: [Meeting], gap: TimeInterval = 120) -> Meeting? {
        meetings
            .filter { m in
                m.id != meeting.id && !m.isAllDay && !m.isCanceled && m.participation != .declined
                    && m.availability != .free && m.start < meeting.start
                    && m.end >= meeting.start.addingTimeInterval(-gap)
            }
            .max { $0.end < $1.end }
    }

    public static func situation(previous: Meeting?, now: Date, onCall: Bool) -> LateSituation {
        guard let previous else { return .late }
        return previous.end > now || onCall ? .overrun : .breather
    }

    /// The other person in a 1:1, or nil for anything bigger.
    public static func oneToOnePartner(_ meeting: Meeting, myEmails: Set<String>) -> Attendee? {
        // Some sources leave the organiser out of the attendee list.
        var people = meeting.attendees
        if let email = meeting.organizerEmail?.lowercased(), !people.contains(where: { $0.email == email }) {
            people.append(Attendee(name: meeting.organizer, email: email))
        }
        let others = people.filter { !isMe($0, myEmails) }
        guard people.count <= 2, others.count == 1 else { return nil }
        return others.first
    }

    /// The suggested message for the situation, filled in.
    public static func suggestion(_ situation: LateSituation, previous: Meeting?, minutes: Int,
                                  settings: LateMessageSettings, myEmails: Set<String>) -> String {
        switch situation {
        case .overrun:
            if settings.mentionName, let previous, let partner = oneToOnePartner(previous, myEmails: myEmails) {
                return fill(settings.overrunWithName, minutes: minutes, name: partner.firstName)
            }
            return fill(settings.overrun, minutes: minutes, name: nil)
        case .breather: return fill(settings.breather, minutes: minutes, name: nil)
        case .late: return fill(settings.late, minutes: minutes, name: nil)
        }
    }

    /// Every message on offer: the suggestion first, then the other built-ins and your own, without repeats.
    public static func options(_ situation: LateSituation, previous: Meeting?, minutes: Int,
                               settings: LateMessageSettings, myEmails: Set<String>) -> [String] {
        let name = settings.mentionName ? previous.flatMap { oneToOnePartner($0, myEmails: myEmails)?.firstName } : nil
        var all = [suggestion(situation, previous: previous, minutes: minutes, settings: settings, myEmails: myEmails)]
        all += [settings.overrun, settings.breather, settings.late].map { fill($0, minutes: minutes, name: nil) }
        all += settings.custom.map { fill($0, minutes: minutes, name: name) }
        var seen = Set<String>()
        return all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
    }

    public static func minutesText(_ minutes: Int) -> String { minutes == 1 ? "1 min" : "\(minutes) mins" }

    public static func fill(_ template: String, minutes: Int, name: String?) -> String {
        template
            .replacingOccurrences(of: "{mins}", with: minutesText(minutes))
            .replacingOccurrences(of: "{name}", with: name ?? "my previous meeting")
    }

    // MARK: Routing

    static func isMe(_ a: Attendee, _ myEmails: Set<String>) -> Bool {
        a.isSelf || a.email.map { myEmails.contains($0) } == true
    }

    /// Group chats beyond this size get a DM to the organiser instead.
    public static let groupChatLimit = 6

    /// The domains that say whose meeting this is, best first: the organiser's, then the one most other
    /// attendees share. Your own domains are skipped.
    public static func domains(for meeting: Meeting, myEmails: Set<String>) -> [String] {
        func domain(_ email: String?) -> String? { email?.split(separator: "@").last.map { $0.lowercased() } }
        let mine = Set(myEmails.compactMap(domain))
        var out: [String] = []
        if let d = domain(meeting.organizerEmail), !mine.contains(d) { out.append(d) }
        let counts = Dictionary(grouping: meeting.attendees.filter { !$0.isResource && !isMe($0, myEmails) }.compactMap { domain($0.email) }, by: { $0 })
            .filter { !mine.contains($0.key) }
        out += counts.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
            .map(\.key).filter { !out.contains($0) }
        if out.isEmpty, let d = domain(meeting.organizerEmail) { out.append(d) }
        return out
    }

    public static func matchingRule(for meeting: Meeting, rules: [LateDomainRule], myEmails: Set<String>) -> LateDomainRule? {
        for d in domains(for: meeting, myEmails: myEmails) {
            if let rule = rules.first(where: { ProfileResolver.domainMatches(email: "x@\(d)", domain: $0.domain) }) { return rule }
        }
        return nil
    }

    /// Everywhere the message could go, from each account, best guess first.
    /// - `preferredAccountIDs`: the account(s) the meeting is "for" (its browser profile, its calendar), best first.
    ///   The best guess never sends from a different account when one of these can do it.
    public static func options(for meeting: Meeting, accounts: [MessagingAccount], rules: [LateDomainRule],
                               preferredAccountIDs: [String], myEmails: Set<String>) -> [LateOption] {
        let mine = Set(myEmails.map { $0.lowercased() } + accounts.compactMap(\.email))
        let organizer = meeting.organizerEmail?.lowercased()
        let iOrganise = organizer.map { mine.contains($0) } ?? false
        let others = meeting.attendees.filter { !$0.isResource && !isMe($0, mine) && $0.email != nil }
        let otherEmails = Array(Set(others.compactMap(\.email))).sorted()
        let rule = matchingRule(for: meeting, rules: rules, myEmails: mine)

        func name(_ email: String) -> String {
            meeting.attendees.first { $0.email == email }?.label
                ?? (organizer == email ? meeting.organizer : nil) ?? email
        }

        // Who a DM goes to: the organiser, or the only other person if you organised it.
        let dmTarget: String? = (!iOrganise ? organizer : nil) ?? (otherEmails.count == 1 ? otherEmails[0] : nil)

        var out: [(option: LateOption, rank: Int)] = []
        func add(_ target: LateTarget, _ label: String, _ account: MessagingAccount, blocked: String?, channelRank: Int) {
            out.append((LateOption(target: target, accountID: account.id, label: label, accountLabel: account.label, blocked: blocked),
                        channelRank))
        }

        let linkKind: LateChannelKind? = switch meeting.joinLink?.service {
        case .teams?: .teams
        case .googleMeet?: .googleChat
        case .slack?: .slack
        default: nil
        }
        // The link's own channel first, then the domain rule's, then email.
        func channelRank(_ kind: LateChannelKind) -> Int {
            if kind == linkKind { return 0 }
            if kind == rule?.channel { return 1 }
            return kind == .email ? 2 : 3
        }

        for account in accounts {
            let noChat = account.canChat ? nil : "Allow running-late messages for \(account.label) in Settings → Accounts"
            let noMail = account.canMail ? nil : noChat
            switch account.kind {
            case .microsoft:
                if case .teams? = meeting.joinLink?.service, let url = meeting.joinLink?.url {
                    add(.teamsMeetingChat(threadID: teamsThreadID(from: url), joinURL: url), "Teams meeting chat", account,
                        blocked: noChat, channelRank: channelRank(.teams))
                }
            case .google:
                let sameOrg = account.domain.map { d in otherEmails.allSatisfy { $0.hasSuffix("@" + d) } } ?? false
                if !otherEmails.isEmpty, otherEmails.count > 1, otherEmails.count <= groupChatLimit, sameOrg {
                    add(.googleGroup(emails: otherEmails), "Google Chat with \(otherEmails.count) people", account,
                        blocked: noChat, channelRank: channelRank(.googleChat))
                }
                if let dm = dmTarget {
                    add(.googleDM(email: dm), "Google Chat → \(name(dm))", account, blocked: noChat, channelRank: channelRank(.googleChat))
                }
            case .slack:
                if case .slack? = meeting.joinLink?.service, let url = meeting.joinLink?.url, let (team, channel) = slackChannel(from: url),
                   team == nil || account.slackTeam == nil || team == account.slackTeam {
                    add(.slackChannel(channel: channel), "Slack huddle channel", account, blocked: noChat, channelRank: channelRank(.slack))
                }
                if let dm = dmTarget {
                    add(.slackDM(email: dm), "Slack → \(name(dm))", account, blocked: noChat, channelRank: channelRank(.slack))
                }
            }
            if account.kind != .slack {
                // Email the organiser; if that's you, everyone else invited.
                let to = (!iOrganise ? organizer.map { [$0] } : nil) ?? otherEmails
                if !to.isEmpty {
                    add(.email(to: to), to.count == 1 ? "Email \(name(to[0]))" : "Email \(to.count) people", account,
                        blocked: noMail, channelRank: channelRank(.email))
                }
            }
        }

        // Rank accounts: the rule's account, then the ones the meeting is for, then the rest.
        var accountOrder: [String] = []
        if let id = rule?.accountID { accountOrder.append(id) }
        accountOrder += preferredAccountIDs.filter { !accountOrder.contains($0) }
        func accountRank(_ id: String) -> Int { accountOrder.firstIndex(of: id) ?? accountOrder.count }

        // A rule's chosen account only counts for its channel; for other channels it ranks like any other.
        func score(_ o: LateOption, _ channel: Int) -> (Int, Int, Int) {
            let usable = o.blocked == nil ? 0 : 1
            var acct = accountRank(o.accountID)
            if let rule, rule.accountID == o.accountID, o.target.kind != rule.channel, o.target.kind != .email { acct += 1 }
            return (usable, acct, channel)
        }
        return out.sorted { a, b in
            let (x, y) = (score(a.option, a.rank), score(b.option, b.rank))
            return x != y ? x < y : a.option.label < b.option.label
        }.map(\.option)
    }

    /// `19:meeting_…@thread.v2` from a classic Teams join link (`/l/meetup-join/19%3ameeting_…%40thread.v2/0?…`).
    public static func teamsThreadID(from url: URL) -> String? {
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let range = raw.range(of: #"19:meeting_[A-Za-z0-9_\-]+@thread\.v2"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }

    /// Team and channel from `https://app.slack.com/huddle/T0123/C0456`.
    public static func slackChannel(from url: URL) -> (team: String?, channel: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(of: "huddle"), parts.count > i + 1 else { return nil }
        let rest = Array(parts[(i + 1)...])
        let channel = rest.last { $0.first == "C" || $0.first == "G" || $0.first == "D" }
        guard let channel else { return nil }
        return (rest.first { $0.first == "T" || $0.first == "E" }, channel)
    }
}
