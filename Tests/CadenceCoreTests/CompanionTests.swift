import Foundation
import Testing
@testable import CadenceCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(_ id: String = "a", link: Bool = true) -> Meeting {
    Meeting(id: id, title: "Design Review", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "Google", color: .gray, kind: .google),
            location: "Room 4", attendeeCount: 5, participation: .accepted,
            joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil,
            eventColor: RGBAColor(red: 1, green: 0, blue: 0), recurs: true, series: "s")
}

@Suite("Companion protocol")
struct CompanionProtocolTests {
    static let messages: [CompanionMessage] = [
        .hello(CompanionHello(deviceID: "d", deviceName: "iPhone", displaying: true)),
        .displayState(displaying: false),
        .join(meetingID: "a"),
        .snooze(meetingID: "a", seconds: 60),
        .dismiss(meetingID: "a"),
        .welcome(macID: "m", macName: "Mac"),
        .snapshot(CompanionSnapshot(macName: "Mac", generatedAt: now, meetings: [meeting(), meeting("b", link: false)],
                                    suppressedIDs: ["b"], takeoverEnabled: false, takeoverLeadSeconds: 45)),
        .alert(meeting()),
        .dismissAlert(meetingID: "a"),
        .reminder(CompanionReminder(key: "k", title: "t", body: "b", joinMeetingID: "a")),
        .ping,
        .bye(reason: "unpaired"),
    ]

    @Test(arguments: messages)
    func roundTrip(message: CompanionMessage) throws {
        var decoder = CompanionFrameDecoder()
        #expect(try decoder.append(CompanionFraming.encode(message)) == [message])
    }

    @Test func framesSplitAndJoined() throws {
        let stream = try Self.messages.map(CompanionFraming.encode).reduce(Data(), +)
        var decoder = CompanionFrameDecoder()
        var out: [CompanionMessage] = []
        var i = stream.startIndex
        while i < stream.endIndex {
            let j = min(stream.endIndex, i + 7)
            out += try decoder.append(stream[i..<j])
            i = j
        }
        #expect(out == Self.messages)
    }

    @Test func garbageFrameSkipped() throws {
        var bad = Data([0, 0, 0, 3])
        bad.append(contentsOf: Array("xyz".utf8))
        var decoder = CompanionFrameDecoder()
        let out = try decoder.append(bad + CompanionFraming.encode(.ping))
        #expect(out == [.ping])
    }

    @Test func oversizedFrameRejected() {
        var decoder = CompanionFrameDecoder()
        #expect(throws: CompanionFramingError.self) { try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF])) }
    }

    @Test func reminderWording() {
        let r = Reminder(key: "heads:5:a", meeting: meeting(), kind: .headsUp(minutes: 5), fireAt: now)
        let c = CompanionReminder(r)
        #expect(c.title == "Design Review in 5 min")
        #expect(c.joinMeetingID == "a")
        let noLink = Reminder(key: "k", meeting: meeting(link: false), kind: .headsUp(minutes: 5), fireAt: now)
        #expect(CompanionReminder(noLink).joinMeetingID == nil)
    }
}

@Suite("Companion routing")
struct CompanionRoutingTests {
    @Test func notDisplayingChangesNothing() {
        for plan in [AlertPlan.fullScreen(displays: [1]), .banner(displays: [1]), .notification, .none] {
            for mode in CompanionTakeoverMode.allCases {
                #expect(CompanionRouting.macPlan(plan, phoneDisplaying: false, mode: mode) == plan)
            }
        }
        #expect(CompanionRouting.macShowsPanel(phoneDisplaying: false))
        #expect(CompanionRouting.macShowsReminders(phoneDisplaying: false))
    }

    @Test func displayingKeepsOnlyFullScreenWhenWanted() {
        let full = AlertPlan.fullScreen(displays: [1, 2])
        #expect(CompanionRouting.macPlan(full, phoneDisplaying: true, mode: .macAndPhone) == full)
        #expect(CompanionRouting.macPlan(full, phoneDisplaying: true, mode: .phoneOnly) == .none)
        for plan in [AlertPlan.banner(displays: [1]), .notification] {
            #expect(CompanionRouting.macPlan(plan, phoneDisplaying: true, mode: .macAndPhone) == .none)
        }
        #expect(!CompanionRouting.macShowsPanel(phoneDisplaying: true))
        #expect(!CompanionRouting.macShowsReminders(phoneDisplaying: true))
    }

    @Test func presentingWhilePhoneDisplays() {
        // Presenting on the only display: the Mac would fall back to a notification; the phone takes it instead.
        let ctx = AlertContext(displays: [DisplaySnapshot(id: 1, bounds: .init(x: 0, y: 0, width: 10, height: 10), isMain: true)],
                               presenting: [PresentingDisplay(displayID: 1, appName: "Keynote")])
        let plan = AlertPolicy.plan(context: ctx, allScreens: true, whilePresenting: .fullScreen, whileOnCall: .banner)
        #expect(plan == .notification)
        #expect(CompanionRouting.macPlan(plan, phoneDisplaying: true, mode: .macAndPhone) == .none)
    }

    @Test func sendsToPhoneOnlyWhenDisplaying() {
        #expect(CompanionRouting.sendsToPhone(connected: true, phoneDisplaying: true))
        #expect(!CompanionRouting.sendsToPhone(connected: true, phoneDisplaying: false))
        #expect(!CompanionRouting.sendsToPhone(connected: false, phoneDisplaying: true))
    }

    @Test func joinDestination() {
        #expect(JoinDestination.choose(connectedToMac: true) == .mac)
        #expect(JoinDestination.choose(connectedToMac: false) == .phone)
    }
}

@Suite("Pairing")
struct PairingTests {
    @Test func roundTrip() {
        let invite = PairingInvite(macID: "mac-1", macName: "Pat's MacBook Pro", key: PairingInvite.newKey())
        #expect(PairingInvite(url: invite.url) == invite)
        #expect(PairingInvite(string: "  \(invite.url.absoluteString)\n") == invite)
    }

    @Test func keysAreRandom() {
        #expect(PairingInvite.newKey() != PairingInvite.newKey())
        #expect(PairingInvite.newKey().count == 32)
    }

    @Test func rejectsBadLinks() {
        #expect(PairingInvite(string: "https://example.com") == nil)
        #expect(PairingInvite(string: "cadence-pair://pair?id=x&k=short") == nil)
        #expect(PairingInvite(string: "cadence-pair://pair?k=" + PairingInvite.base64URL(PairingInvite.newKey())) == nil)
    }
}
