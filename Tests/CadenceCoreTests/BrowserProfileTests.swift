import Foundation
import Testing
@testable import CadenceCore

private let chromeLocalState = """
{"browser":{"enabled_labs_experiments":[]},
 "profile":{"last_used":"Profile 5","info_cache":{
   "Default":{"name":"Personal","user_name":""},
   "Profile 5":{"name":"Agency","user_name":"me@agency.example","gaia_name":"Me"},
   "Profile 6":{"name":"Client A","user_name":"me@clienta.example"},
   "Profile 7":{"name":"Client B"},
   "Broken":"nope"}}}
""".data(using: .utf8)!

private let profilesINI = """
[Install4F96D1932A9F858E]
Default=Profiles/abc.default-release
Locked=1

[Profile1]
Name=Client A
IsRelative=1
Path=Profiles/xyz.client-a

[Profile0]
Name=default-release
IsRelative=1
Path=Profiles/abc.default-release
Default=1

[Profile2]
Name=External
IsRelative=0
Path=/Volumes/Disk/ff-external

[General]
StartWithLastProfile=1
Version=2
"""

private let agency = BrowserProfile(browser: .chrome, directory: "Profile 5", name: "Agency", email: "me@agency.example")
private let clientA = BrowserProfile(browser: .chrome, directory: "Profile 6", name: "Client A", email: "me@clienta.example")
private let clientB = BrowserProfile(browser: .chrome, directory: "Profile 7", name: "Client B")
private let all = [agency, clientA, clientB]

private func meeting(id: String = "ev1@1700000000", calendarID: String = "cal-work", source: String = "Google · me@agency.example",
                     organizerEmail: String? = nil, service: MeetingService = .googleMeet, url: String = "https://meet.google.com/abc-defg-hij",
                     series: String? = nil) -> Meeting {
    Meeting(id: id, title: "Sync", start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_001_800),
            calendar: CalendarInfo(id: calendarID, title: "Work", sourceTitle: source, color: .gray),
            organizerEmail: organizerEmail,
            joinLink: MeetingLink(service: service, url: URL(string: url)!), series: series)
}

@Suite("Browser profiles")
struct BrowserProfileTests {
    @Test func parsesChromiumLocalState() {
        let profiles = BrowserProfiles.parseChromium(localState: chromeLocalState, browser: .chrome)
        #expect(profiles.map(\.name) == ["Agency", "Client A", "Client B", "Personal"])
        #expect(profiles.first { $0.name == "Agency" }?.email == "me@agency.example")
        #expect(profiles.first { $0.name == "Personal" }?.email == nil)
        #expect(profiles.first { $0.name == "Client A" }?.id == "chrome/Profile 6")
        #expect(BrowserProfiles.parseChromium(localState: Data("{not json".utf8), browser: .chrome).isEmpty)
        #expect(BrowserProfiles.parseChromium(localState: Data("{\"profile\":{}}".utf8), browser: .edge).isEmpty)
    }

    @Test func parsesFirefoxProfilesINI() {
        let base = URL(fileURLWithPath: "/Users/x/Library/Application Support/Firefox")
        let profiles = BrowserProfiles.parseFirefox(profilesINI: profilesINI, base: base)
        #expect(profiles.map(\.name) == ["Client A", "default-release", "External"])
        #expect(profiles[0].directory == "/Users/x/Library/Application Support/Firefox/Profiles/xyz.client-a")
        #expect(profiles[2].directory == "/Volumes/Disk/ff-external")
        #expect(profiles.allSatisfy { $0.browser == .firefox })
    }

    @Test func launchArgumentsKeepURLAsOneArgument() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting?context=%7b%22Tid%22%7d&x=1;rm -rf")!
        #expect(clientA.launchArguments(for: url) == ["--profile-directory=Profile 6", url.absoluteString])

        let ff = BrowserProfile(browser: .firefox, directory: "/p/xyz", name: "Client A")
        #expect(ff.launchArguments(for: url) == ["--profile", "/p/xyz", "-new-tab", url.absoluteString])

        var box = ff
        box.container = "Client & Co"
        let args = box.launchArguments(for: URL(string: "https://zoom.us/j/1?pwd=a&b=c")!)
        #expect(args.last == "ext+container:name=Client%20%26%20Co&url=https%3A%2F%2Fzoom.us%2Fj%2F1%3Fpwd%3Da%26b%3Dc")
        #expect(box.id == "firefox//p/xyz#Client & Co")
        #expect(box.title == "Client A › Client & Co")
    }

    @Test func browserFromBundleID() {
        #expect(ProfileBrowser(bundleID: "com.google.Chrome") == .chrome)
        #expect(ProfileBrowser(bundleID: "org.mozilla.firefox") == .firefox)
        #expect(ProfileBrowser(bundleID: "com.apple.Safari") == nil)
    }

    @Test func resolverPrecedence() {
        var rules = ProfileRules()
        rules.accounts["Google · me@agency.example"] = agency.id
        let m = meeting(organizerEmail: "boss@clienta.example", series: "series-1")
        #expect(ProfileResolver.resolve(m, rules: rules, profiles: all)?.source == .account)

        rules.calendars["cal-work"] = clientB.id
        #expect(ProfileResolver.resolve(m, rules: rules, profiles: all)?.profile == clientB)

        rules.domains = [DomainProfileRule(domain: "clienta.example", profileID: clientA.id)]
        let byDomain = ProfileResolver.resolve(m, rules: rules, profiles: all)
        #expect(byDomain?.profile == clientA)
        #expect(byDomain?.reason == "Organizer @clienta.example")

        rules.series["series-1"] = agency.id
        #expect(ProfileResolver.resolve(m, rules: rules, profiles: all)?.source == .series)

        rules.meetings[m.id] = clientB.id
        #expect(ProfileResolver.resolve(m, rules: rules, profiles: all)?.source == .meeting)
        #expect(ProfileResolver.resolve(meeting(source: "iCloud"), rules: ProfileRules(), profiles: all) == nil)
    }

    @Test func missingOrOtherBrowserProfileIsSkipped() {
        var rules = ProfileRules()
        rules.calendars["cal-work"] = "chrome/Profile 99"
        rules.accounts["Google · me@agency.example"] = agency.id
        #expect(ProfileResolver.resolve(meeting(), rules: rules, profiles: all)?.profile == agency)

        // Default browser switched to Firefox: the Chrome rules find nothing, so the default browser opens it.
        let firefox = [BrowserProfile(browser: .firefox, directory: "/p/a", name: "A")]
        #expect(ProfileResolver.resolve(meeting(), rules: rules, profiles: firefox) == nil)
    }

    @Test func domainMatching() {
        #expect(ProfileResolver.domainMatches(email: "a@clienta.example", domain: "clienta.example"))
        #expect(ProfileResolver.domainMatches(email: "a@EU.ClientA.example", domain: "@clienta.example "))
        #expect(ProfileResolver.domainMatches(email: "a@clienta.example", domain: ".clienta.example"))
        #expect(!ProfileResolver.domainMatches(email: "a@evil-clienta.example", domain: "clienta.example"))
        #expect(!ProfileResolver.domainMatches(email: "a@clienta.example.evil", domain: "clienta.example"))
        #expect(!ProfileResolver.domainMatches(email: "no-at-sign", domain: "clienta.example"))
        #expect(!ProfileResolver.domainMatches(email: "a@clienta.example", domain: "  "))
    }

    @Test func nativeAppOverride() {
        let rules = ProfileRules() // Teams overrides by default
        let teams = MeetingLink(service: .teams, url: URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!)
        let zoom = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/123456789")!)
        let choice = ProfileChoice(profile: clientA, source: .calendar, reason: "")
        let has: (URL) -> Bool = { _ in true }

        #expect(ProfileResolver.route(for: teams, choice: choice, rules: rules, preferNative: true, nativeAvailable: has) == .profile(clientA, teams.url))
        #expect(ProfileResolver.route(for: teams, choice: nil, rules: rules, preferNative: true, nativeAvailable: has) == .native(teams.nativeURL!))
        #expect(ProfileResolver.route(for: zoom, choice: choice, rules: rules, preferNative: true, nativeAvailable: has) == .native(zoom.nativeURL!))
        #expect(ProfileResolver.route(for: zoom, choice: choice, rules: rules, preferNative: false, nativeAvailable: has) == .profile(clientA, zoom.url))
        #expect(ProfileResolver.route(for: zoom, choice: choice, rules: rules, preferNative: true, nativeAvailable: { _ in false }) == .profile(clientA, zoom.url))
        #expect(ProfileResolver.route(for: zoom, choice: nil, rules: rules, preferNative: false, nativeAvailable: has) == .defaultBrowser(zoom.url))

        var zoomToo = rules
        zoomToo.nativeOverride.insert(.zoom)
        #expect(ProfileResolver.route(for: zoom, choice: choice, rules: zoomToo, preferNative: true, nativeAvailable: has) == .profile(clientA, zoom.url))
    }

    @Test func suggestions() {
        #expect(ProfileResolver.suggest(accountTitle: "Google · me@clienta.example", profiles: all) == clientA)
        #expect(ProfileResolver.suggest(accountTitle: "Microsoft · other@agency.example", profiles: all) == agency)
        #expect(ProfileResolver.suggest(accountTitle: "iCloud", profiles: all) == nil)
        #expect(ProfileResolver.suggest(accountTitle: "Google · x@unknown.example", profiles: all) == nil)
    }

    @Test func rulesDecodeFromOlderOrPartialData() throws {
        let rules = try JSONDecoder().decode(ProfileRules.self, from: Data(#"{"calendars":{"a":"chrome/Default"}}"#.utf8))
        #expect(rules.calendars["a"] == "chrome/Default")
        #expect(rules.nativeOverride == [.teams])
        let round = try JSONDecoder().decode(ProfileRules.self, from: JSONEncoder().encode(rules))
        #expect(round == rules)
    }

    @Test func organizerEmailFromICS() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:1
        DTSTART:20250101T100000Z
        DTEND:20250101T110000Z
        SUMMARY:Sync
        ORGANIZER;CN=Boss:mailto:boss@clienta.example
        END:VEVENT
        BEGIN:VEVENT
        UID:2
        DTSTART:20250101T120000Z
        DTEND:20250101T130000Z
        SUMMARY:No mail
        ORGANIZER;CN=Someone:urn:x
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(ics)
        #expect(events.first { $0.uid == "1" }?.organizerEmail == "boss@clienta.example")
        #expect(events.first { $0.uid == "1" }?.organizer == "Boss")
        #expect(events.first { $0.uid == "2" }?.organizerEmail == nil)
    }

    @Test func dedupKeepsOrganizerEmail() {
        var a = meeting(organizerEmail: nil)
        a.joinLink = nil
        var b = meeting(id: "other@1700000000", calendarID: "cal-2", organizerEmail: "boss@clienta.example")
        b.title = a.title
        let merged = MeetingDeduplicator.dedupe([a, b])
        #expect(merged.count == 1)
        #expect(merged.first?.organizerEmail == "boss@clienta.example")
    }
}
