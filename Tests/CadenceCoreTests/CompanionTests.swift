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
        .address(hosts: ["192.168.0.21"], port: 62166),
        .features(["joinMeeting"]),
        .joinMeeting(meeting()),
        .rsvp(meetingID: "m1", reply: .accept),
        .rsvp(meetingID: "m1", reply: nil),
        .inviteLater(meetingID: "m1"),
        .resolveClash(key: "a|b", choice: "all"),
        .resolveClash(key: "a|b", choice: nil),
        .inviteHandled(meetingID: "m1"),
        .clashHandled(key: "a|b"),
        .snapshot(CompanionSnapshot(macName: "Mac", generatedAt: now, meetings: [meeting(), meeting("b", link: false)],
                                    suppressedIDs: ["b"], takeoverEnabled: false, takeoverLeadSeconds: 45)),
        .alert(meeting()),
        .invitePrompt([CompanionInvite(meeting: meeting(), canRespond: true), CompanionInvite(meeting: meeting("b"), canRespond: false)]),
        .clashPrompt(CompanionClash(key: "a|b", meetings: [meeting(), meeting("b")])),
        .dismissAlert(meetingID: "a"),
        .reminder(CompanionReminder(key: "k", title: "t", body: "b", joinMeetingID: "a")),
        .media(CompanionMedia(app: .appleMusic, title: "Song", artist: "Band", isPlaying: true,
                              artwork: Data([0xFF, 0xD8]), trackID: "appleMusic-1", canSkip: true)),
        .media(CompanionMedia(app: .spotify, isPlaying: false)),
        .media(CompanionMedia(app: .system, isPlaying: true, trackID: "other-system")),
        .media(nil),
        .mediaCommand(.togglePlayPause),
        .mediaCommand(.next),
        .mediaCommand(.volumeUp),
        .mediaCommand(.toggleMute),
        .volume(level: 0.4375, muted: false),
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

    /// A message from a newer peer (a case this build doesn't know) is skipped, not fatal.
    @Test func unknownMessageSkipped() throws {
        let future = Data(#"{"somethingNew":{"x":1}}"#.utf8)
        var length = UInt32(future.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(future)
        var decoder = CompanionFrameDecoder()
        #expect(try decoder.append(frame + CompanionFraming.encode(.ping)) == [.ping])
    }

    @Test func unknownMediaAppShowsAsAudio() throws {
        let json = Data(#"{"app":"tidal","isPlaying":true,"canSkip":false}"#.utf8)
        let media = try JSONDecoder().decode(CompanionMedia.self, from: json)
        #expect(media.app == .system)
        #expect(media.isPlaying)
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

@Suite("Escalation to the Mac")
struct EscalationTests {
    @Test func countsFromTheStart() {
        let start = now.addingTimeInterval(30)
        #expect(CompanionEscalation.thirtySeconds.date(start: start, now: now) == start.addingTimeInterval(30))
        #expect(CompanionEscalation.twoMinutes.date(start: start, now: now) == start.addingTimeInterval(120))
    }

    @Test func lateAlertEscalatesNow() {
        let start = now.addingTimeInterval(-300)
        #expect(CompanionEscalation.oneMinute.date(start: start, now: now) == now)
    }

    @Test func offNeverEscalates() {
        #expect(CompanionEscalation.off.date(start: now, now: now) == nil)
    }
}

@Suite("Pairing")
struct PairingTests {
    @Test func roundTrip() {
        let invite = PairingInvite(macID: "mac-1", macName: "Pat's MacBook Pro", key: PairingInvite.newKey())
        #expect(PairingInvite(url: invite.url) == invite)
        #expect(PairingInvite(string: "  \(invite.url.absoluteString)\n") == invite)
    }

    @Test func carriesDirectAddress() {
        let direct = PairingInvite(macID: "mac-1", macName: "Mac", key: PairingInvite.newKey(),
                                   hosts: ["192.168.0.21", "10.0.0.4"], port: 58168)
        #expect(PairingInvite(url: direct.url) == direct)
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

@Suite("Per-phone keys")
struct CompanionKeyTests {
    @Test func inviteCarriesKeyID() throws {
        let invite = PairingInvite(macID: "mac", macName: "Mac", key: PairingInvite.newKey(), keyID: "abc123")
        let back = try #require(PairingInvite(url: invite.url))
        #expect(back.keyID == "abc123")
        #expect(back.key == invite.key)
        // Codes from older Macs have no key id: the shared key.
        let old = PairingInvite(macID: "mac", macName: "Mac", key: invite.key)
        #expect(PairingInvite(url: old.url)?.keyID == nil)
    }

    @Test func identities() {
        #expect(CompanionKeys.identity(for: nil) == "cadence")
        #expect(CompanionKeys.identity(for: "k1") == "cadence.k1")
        #expect(CompanionKeys.newKeyID() != CompanionKeys.newKeyID())
    }

    @Test func proofBindsKeyAndSession() {
        let key = PairingInvite.newKey(), other = PairingInvite.newKey()
        let session = Data(repeating: 7, count: 32), otherSession = Data(repeating: 8, count: 32)
        let proof = CompanionKeys.proof(key: key, binding: session)
        #expect(CompanionKeys.verify(proof, key: key, binding: session))
        #expect(!CompanionKeys.verify(proof, key: other, binding: session))
        // Replayed on another connection.
        #expect(!CompanionKeys.verify(proof, key: key, binding: otherSession))
        #expect(!CompanionKeys.verify(Data(), key: key, binding: session))
    }

    @Test func rekeyAndProofTravel() throws {
        let key = PairingInvite.newKey()
        let rekey = CompanionMessage.rekey(keyID: "k1", key: key)
        var decoder = CompanionFrameDecoder()
        #expect(try decoder.append(CompanionFraming.encode(rekey)) == [rekey])
        let hello = CompanionMessage.hello(CompanionHello(deviceID: "p", deviceName: "iPhone", displaying: false,
                                                          keyID: "k1", proof: Data([1, 2, 3])))
        #expect(try decoder.append(CompanionFraming.encode(hello)) == [hello])
    }

    @Test func olderHelloStillDecodes() throws {
        let json = #"{"hello":{"_0":{"protocolVersion":1,"deviceID":"p","deviceName":"iPhone","displaying":true}}}"#
        let message = try CompanionFraming.decodeBody(Data(json.utf8))
        guard case .hello(let hello) = message else { Issue.record("not a hello"); return }
        #expect(hello.keyID == nil && hello.proof == nil)
    }
}
