import Foundation
import Testing
@testable import CadenceCore

private let cal = CalendarInfo(id: "c", title: "Work", sourceTitle: "Test", color: .gray)
private let me = "me@example.com"

private func meeting(_ id: String, start: Date, minutes: Double = 30, link: MeetingLink? = nil,
                     organizer: String? = nil, attendees: [Attendee] = []) -> Meeting {
    Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), calendar: cal,
            organizer: organizer.map { $0.split(separator: "@").first.map(String.init) ?? $0 },
            organizerEmail: organizer, attendeeCount: attendees.count, attendees: attendees, joinLink: link)
}

@Suite("Running late")
struct RunningLateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func previousMeetingAndSituation() {
        let current = meeting("now", start: now.addingTimeInterval(-60))
        let overrunning = meeting("prev", start: now.addingTimeInterval(-1800), minutes: 31) // ends 1 min from now
        let finished = meeting("prev", start: now.addingTimeInterval(-1860), minutes: 30)   // ended right at the start
        let longAgo = meeting("old", start: now.addingTimeInterval(-7200))

        #expect(RunningLate.previous(to: current, in: [current, longAgo]) == nil)
        #expect(RunningLate.situation(previous: nil, now: now, onCall: false) == .late)

        let p1 = RunningLate.previous(to: current, in: [current, overrunning, longAgo])
        #expect(p1?.id == "prev")
        #expect(RunningLate.situation(previous: p1, now: now, onCall: false) == .overrun)

        let p2 = RunningLate.previous(to: current, in: [current, finished])
        #expect(RunningLate.situation(previous: p2, now: now, onCall: false) == .breather)
        #expect(RunningLate.situation(previous: p2, now: now, onCall: true) == .overrun)
    }

    @Test func suggestionsFillPlaceholders() {
        var s = LateMessageSettings()
        let oneToOne = meeting("1:1", start: now, organizer: "roy.smith@example.com",
                               attendees: [Attendee(name: "Me", email: me, isSelf: true)])
        #expect(RunningLate.suggestion(.late, previous: nil, minutes: 2, settings: s, myEmails: [me])
                == "Running a few minutes late, sorry! Be there in 2 mins.")
        #expect(RunningLate.suggestion(.overrun, previous: oneToOne, minutes: 5, settings: s, myEmails: [me])
                == "Just wrapping up my previous meeting — there in 5 mins!")
        s.mentionName = true
        // The organiser is missing from the attendee list here; it still counts as a 1:1.
        #expect(RunningLate.suggestion(.overrun, previous: oneToOne, minutes: 5, settings: s, myEmails: [me])
                == "Just wrapping up with Roy — there in 5 mins!")
        let group = meeting("group", start: now, attendees: [
            Attendee(email: me), Attendee(name: "A", email: "a@x.com"), Attendee(name: "B", email: "b@x.com"),
        ])
        #expect(RunningLate.suggestion(.overrun, previous: group, minutes: 2, settings: s, myEmails: [me])
                == "Just wrapping up my previous meeting — there in 2 mins!")
    }

    @Test func optionsPutSuggestionFirstWithoutRepeats() {
        var s = LateMessageSettings()
        s.custom = ["Be right there ({mins})", "", "Be right there ({mins})"]
        let o = RunningLate.options(.breather, previous: nil, minutes: 10, settings: s, myEmails: [])
        #expect(o.first == "Grabbing a quick breather between back-to-backs — there in 10 mins!")
        #expect(o.count == 4)
        #expect(o.last == "Be right there (10 mins)")
    }

    @Test func teamsThreadFromJoinLink() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NDRiZjRiMmUtODI5OC00MzRl%40thread.v2/0?context=%7b%7d")!
        #expect(RunningLate.teamsThreadID(from: url) == "19:meeting_NDRiZjRiMmUtODI5OC00MzRl@thread.v2")
        #expect(RunningLate.teamsThreadID(from: URL(string: "https://teams.microsoft.com/meet/123456?p=abc")!) == nil)
    }

    @Test func slackHuddleChannel() {
        let r = RunningLate.slackChannel(from: URL(string: "https://app.slack.com/huddle/T012AB3C4/C0123456789")!)
        #expect(r?.team == "T012AB3C4")
        #expect(r?.channel == "C0123456789")
        #expect(RunningLate.slackChannel(from: URL(string: "https://app.slack.com/client/T1")!) == nil)
    }

    // Accounts: a client Google Workspace, your own Microsoft 365, a Slack workspace, and one with nothing allowed.
    let clientG = MessagingAccount(id: "g", kind: .google, email: "me@client.com", label: "me@client.com", canMail: true, canChat: true)
    let ownMS = MessagingAccount(id: "m", kind: .microsoft, email: me, label: me, canMail: true, canChat: true)
    let slack = MessagingAccount(id: "s", kind: .slack, email: nil, label: "Agency", canMail: false, canChat: true, slackTeam: "T1")
    let locked = MessagingAccount(id: "l", kind: .google, email: "me@other.com", label: "me@other.com", canMail: false, canChat: false)
    var mine: Set<String> { [me, "me@client.com", "me@other.com"] }

    @Test func teamsLinkPrefersMeetingChat() {
        let teams = MeetingLink(service: .teams, url: URL(string: "https://teams.microsoft.com/meet/1?p=2")!)
        let t = meeting("t", start: now, link: teams, organizer: "boss@example.com",
                        attendees: [Attendee(email: me), Attendee(name: "Boss", email: "boss@example.com")])
        let o = RunningLate.options(for: t, accounts: [clientG, ownMS, slack], rules: [], preferredAccountIDs: ["m"], myEmails: mine)
        #expect(o.first?.target == .teamsMeetingChat(threadID: nil, joinURL: teams.url))
        #expect(o.first?.accountID == "m")
        #expect(o.contains { $0.target == .email(to: ["boss@example.com"]) && $0.accountID == "m" })
        #expect(o.contains { $0.target == .slackDM(email: "boss@example.com") })
    }

    @Test func meetGoesToGroupChatForSmallSameOrgMeetings() {
        let meet = MeetingLink(service: .googleMeet, url: URL(string: "https://meet.google.com/abc-mnop-xyz")!)
        let small = meeting("m", start: now, link: meet, organizer: "me@client.com", attendees: [
            Attendee(email: "me@client.com", isSelf: true), Attendee(name: "Sam", email: "sam@client.com"),
            Attendee(email: "kim@client.com"), Attendee(name: "Room 4", email: "room4@resource.client.com", isResource: true),
        ])
        let o = RunningLate.options(for: small, accounts: [clientG, ownMS], rules: [], preferredAccountIDs: ["g"], myEmails: mine)
        #expect(o.first?.target == .googleGroup(emails: ["kim@client.com", "sam@client.com"]))
        #expect(o.first?.accountID == "g")
        // The room never gets an email.
        #expect(!o.contains { if case .email(let to) = $0.target { to.contains { $0.hasPrefix("room4") } } else { false } })

        let external = meeting("x", start: now, link: meet, organizer: "pat@elsewhere.com",
                               attendees: [Attendee(email: "me@client.com"), Attendee(email: "pat@elsewhere.com"), Attendee(email: "kim@client.com")])
        let ox = RunningLate.options(for: external, accounts: [clientG], rules: [], preferredAccountIDs: ["g"], myEmails: mine)
        #expect(ox.first?.target == .googleDM(email: "pat@elsewhere.com"))
    }

    @Test func domainRuleChoosesChannelAndAccount() {
        let zoom = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        let z = meeting("z", start: now, link: zoom, organizer: "lead@agency.example",
                        attendees: [Attendee(email: me), Attendee(name: "Lead", email: "lead@agency.example")])
        let rules = [LateDomainRule(domain: "agency.example", channel: .slack, accountID: "s")]
        let o = RunningLate.options(for: z, accounts: [clientG, ownMS, slack], rules: rules, preferredAccountIDs: ["m"], myEmails: mine)
        #expect(o.first?.target == .slackDM(email: "lead@agency.example"))
        #expect(o.first?.accountID == "s")
        // Without the rule, email from the account the meeting is for.
        let plain = RunningLate.options(for: z, accounts: [clientG, ownMS, slack], rules: [], preferredAccountIDs: ["m"], myEmails: mine)
        #expect(plain.first?.target == .email(to: ["lead@agency.example"]))
        #expect(plain.first?.accountID == "m")
        #expect(RunningLate.matchingRule(for: z, rules: [LateDomainRule(domain: "example", channel: .teams)], myEmails: mine)?.channel == .teams)
    }

    @Test func blockedOptionsSinkToTheBottom() {
        let meet = MeetingLink(service: .googleMeet, url: URL(string: "https://meet.google.com/abc-mnop-xyz")!)
        let m = meeting("m", start: now, link: meet, organizer: "sam@other.com", attendees: [Attendee(email: "sam@other.com")])
        let o = RunningLate.options(for: m, accounts: [locked, ownMS], rules: [], preferredAccountIDs: ["l"], myEmails: mine)
        #expect(o.first?.blocked == nil)
        #expect(o.first?.accountID == "m")
        #expect(o.last?.blocked != nil)
    }

    @Test func meetingDomains() {
        let m = meeting("d", start: now, organizer: me, attendees: [
            Attendee(email: me), Attendee(email: "a@client.com"), Attendee(email: "b@client.com"), Attendee(email: "c@vendor.com"),
        ])
        #expect(RunningLate.domains(for: m, myEmails: [me]) == ["client.com", "vendor.com"])
    }

    @Test func settingsDecodeMissingKeys() throws {
        let s = try JSONDecoder().decode(LateMessageSettings.self, from: Data(#"{"custom":["Hi"]}"#.utf8))
        #expect(s.custom == ["Hi"])
        #expect(s.defaultMinutes == 2)
        #expect(s.late == LateMessageSettings().late)
    }
}
