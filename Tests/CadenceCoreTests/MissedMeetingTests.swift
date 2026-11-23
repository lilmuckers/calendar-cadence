import Foundation
import Testing
@testable import CadenceCore

private let now = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!

private func m(_ id: String, at minutes: Double, for length: Double = 30, link: Bool = true) -> Meeting {
    Meeting(id: id, title: id, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
            calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray),
            joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil)
}

@Suite("Live Activity: joined and missed meetings")
struct MissedMeetingTests {
    private func focus(_ ms: [Meeting], joined: Set<String> = [], linger: MissedMeetingLinger = .fiveMinutes) -> ActivityPlanner.Focus? {
        ActivityPlanner.focus(meetings: ms, now: now, isHidden: { _ in false }, hasJoined: { joined.contains($0.id) }, linger: linger)
    }

    @Test func hideDates() {
        let start = now, end = now.addingTimeInterval(1800)
        #expect(MissedMeetingLinger.immediately.hideDate(start: start, end: end) == start)
        #expect(MissedMeetingLinger.twoMinutes.hideDate(start: start, end: end) == start.addingTimeInterval(120))
        #expect(MissedMeetingLinger.indefinitely.hideDate(start: start, end: end) == end)
        // Never outlasts the meeting.
        #expect(MissedMeetingLinger.tenMinutes.hideDate(start: start, end: start.addingTimeInterval(300)) == start.addingTimeInterval(300))
    }

    @Test func upcomingMeetingCarriesItsMissedTime() {
        let f = focus([m("a", at: 10)])
        #expect(f?.meeting.id == "a")
        #expect(f?.live == false)
        #expect(f?.missedUntil == now.addingTimeInterval(15 * 60))
    }

    @Test func startedUnjoinedIsMissedUntilLingerIsUp() {
        let f = focus([m("a", at: -3)])
        #expect(f?.meeting.id == "a")
        #expect(f?.live == false)
        #expect(focus([m("a", at: -6)]) == nil)
        #expect(focus([m("a", at: -1)], linger: .immediately) == nil)
        #expect(focus([m("a", at: -25)], linger: .indefinitely)?.meeting.id == "a")
        #expect(focus([m("a", at: -31)], linger: .indefinitely) == nil)
    }

    @Test func joinedMeetingGoesAway() {
        #expect(focus([m("a", at: -3)], joined: ["a"]) == nil)
        // Joined early: drops out before it starts too, and the next one takes over.
        #expect(focus([m("a", at: 2), m("b", at: 40)], joined: ["a"])?.meeting.id == "b")
    }

    @Test func meetingWithoutLinkCountsDownToItsEnd() {
        let f = focus([m("a", at: -3, link: false)])
        #expect(f?.live == true)
        #expect(f?.missedUntil == nil)
    }

    @Test func nextMeetingTakesOverFromAMissedOne() {
        #expect(focus([m("a", at: -6), m("b", at: 20)])?.meeting.id == "b")
        // Still missed, but the next one is close: the next one wins (as on the Mac's panel).
        #expect(focus([m("a", at: -2), m("b", at: 5)])?.meeting.id == "b")
    }

    @Test func snapshotJoinedIDsRoundTrip() throws {
        let snap = CompanionSnapshot(macName: "Mac", generatedAt: now, meetings: [], joinedIDs: ["a"])
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(CompanionSnapshot.self, from: data).joinedIDs == ["a"])
    }
}
