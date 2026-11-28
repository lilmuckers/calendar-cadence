import Foundation
import Testing
@testable import CadenceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func m(_ id: String, _ title: String? = nil, at minutes: Double, for length: Double = 30, location: String? = nil) -> Meeting {
    Meeting(id: id, title: title ?? id, start: t0.addingTimeInterval(minutes * 60), end: t0.addingTimeInterval((minutes + length) * 60),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray), location: location)
}

@Suite("Reminders")
struct ReminderTests {
    @Test func headsUpFiresOnceInWindow() {
        let r = ReminderPlanner.headsUps(for: [m("a", at: 10)], minutes: 5)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(4 * 60), sent: []).isEmpty)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(5 * 60), sent: []).count == 1)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(5 * 60), sent: [r[0].key]).isEmpty)
    }

    @Test func staleRemindersAreDropped() {
        let r = ReminderPlanner.headsUps(for: [m("a", at: 10)], minutes: 5)
        #expect(ReminderPlanner.due(r, now: t0.addingTimeInterval(9 * 60), sent: []).isEmpty)
    }

    @Test func leaveOffsets() {
        let meeting = m("a", at: 60, location: "1 Main St")
        let r = ReminderPlanner.leaves(for: meeting, travel: 25 * 60, offsets: [0, 10, 10])
        #expect(r.count == 2)
        #expect(r.map(\.fireAt) == [t0.addingTimeInterval(25 * 60), t0.addingTimeInterval(35 * 60)])
        let msg = ReminderPlanner.message(for: r[1])
        #expect(msg.title == "Time to leave for a")
        #expect(msg.body.contains("25m"))
        #expect(ReminderPlanner.message(for: r[0]).title == "Leave in 10 min for a")
    }

    @Test func leaveOffsetLabels() {
        #expect(LeaveOffsets.label(0) == "When it's time to leave")
        #expect(LeaveOffsets.label(1) == "1 minute before leaving")
        #expect(LeaveOffsets.label(10) == "10 minutes before leaving")
        #expect(LeaveOffsets.label(60) == "1 hour before leaving")
        #expect(LeaveOffsets.label(120) == "2 hours before leaving")
        #expect(LeaveOffsets.label(90) == "1 hr 30 min before leaving")
    }

    @Test func leaveOffsetsNormalizeStoredValues() {
        // Values typed into the old free-text field stay valid: deduped, in range, largest first.
        #expect(LeaveOffsets.normalized([0, 10, 10, 300, -5, 7]) == [10, 7, 0])
        #expect(LeaveOffsets.available(excluding: [10, 0]).contains(10) == false)
        #expect(LeaveOffsets.available(excluding: [10, 0]).contains(5))
    }
}

@Suite("Clashes")
struct ClashTests {
    @Test func overlapsCluster() {
        let c = ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 15), m("c", at: 45), m("d", at: 120)], after: t0)
        #expect(c.count == 1)
        #expect(c[0].meetings.map(\.id) == ["a", "b"])
    }

    @Test func backToBackAndCopiesAreFine() {
        #expect(ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 30)], after: t0).isEmpty)
        #expect(ClashDetector.clashes(in: [m("a", "Sync", at: 0), m("b", "Sync", at: 0)], after: t0).isEmpty)
    }

    @Test func chainedOverlapsFormOneCluster() {
        let c = ClashDetector.clashes(in: [m("a", at: 0, for: 60), m("b", at: 30), m("c", at: 50)], after: t0)
        #expect(c.first?.meetings.count == 3)
    }

    // Issue #101: a meeting ending at 13:00 and one starting at 13:00 are back-to-back, not a clash.
    @Test func backToBackIsNotAClash() {
        #expect(ClashDetector.clashes(in: [m("a", at: 0, for: 60), m("b", at: 60, for: 60)], after: t0).isEmpty)
        // Order in the input doesn't matter.
        #expect(ClashDetector.clashes(in: [m("b", at: 60, for: 60), m("a", at: 0, for: 60)], after: t0).isEmpty)
        // A run of three back-to-back meetings.
        #expect(ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 30), m("c", at: 60)], after: t0).isEmpty)
    }

    @Test(arguments: [0.001, 0.4, 0.999, 1, 5, 29, 30])
    func backToBackWithStraySecondsIsNotAClash(drift: Double) {
        let cal = CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray)
        let thirteen = t0.addingTimeInterval(60 * 60)
        // End stored a fraction (or a few seconds) late, as some feeds do.
        let a = Meeting(id: "a", title: "a", start: t0, end: thirteen.addingTimeInterval(drift), calendar: cal)
        let b = Meeting(id: "b", title: "b", start: thirteen, end: thirteen.addingTimeInterval(3600), calendar: cal)
        #expect(ClashDetector.clashes(in: [a, b], after: t0).isEmpty)
        // Or the next start a fraction early.
        let c = Meeting(id: "c", title: "c", start: thirteen.addingTimeInterval(-drift), end: thirteen.addingTimeInterval(3600), calendar: cal)
        let d = Meeting(id: "d", title: "d", start: t0, end: thirteen, calendar: cal)
        #expect(ClashDetector.clashes(in: [d, c], after: t0).isEmpty)
    }

    @Test func overlapPastTheDefaultToleranceIsAClash() {
        let cal = CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray)
        func pair(overlap: TimeInterval) -> [Meeting] {
            [Meeting(id: "a", title: "a", start: t0, end: t0.addingTimeInterval(3600 + overlap), calendar: cal),
             Meeting(id: "b", title: "b", start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(7200), calendar: cal)]
        }
        #expect(ClashDetector.defaultOverlapTolerance == 30)
        #expect(ClashDetector.clashes(in: pair(overlap: 30), after: t0).isEmpty)
        let c = ClashDetector.clashes(in: pair(overlap: 31), after: t0)
        #expect(c.count == 1)
        #expect(c.first?.meetings.map(\.id) == ["a", "b"])
        // And when the second starts early instead.
        #expect(ClashDetector.clashes(in: [m("a", at: 0, for: 60), m("b", at: 59, for: 60)], after: t0).count == 1)
    }

    @Test(arguments: ClashDetector.overlapToleranceOptions)
    func toleranceIsTheMostOverlapAllowed(tolerance: TimeInterval) {
        let cal = CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray)
        func pair(overlap: TimeInterval) -> [Meeting] {
            [Meeting(id: "a", title: "a", start: t0, end: t0.addingTimeInterval(3600 + overlap), calendar: cal),
             Meeting(id: "b", title: "b", start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(7200), calendar: cal)]
        }
        #expect(ClashDetector.clashes(in: pair(overlap: tolerance), after: t0, tolerance: tolerance).isEmpty)
        #expect(ClashDetector.clashes(in: pair(overlap: tolerance + 1), after: t0, tolerance: tolerance).count == 1)
    }

    @Test func toleranceOptionsAndLabels() {
        #expect(ClashDetector.overlapToleranceOptions.first == 1)
        #expect(ClashDetector.overlapToleranceOptions.last == 300)
        #expect(ClashDetector.overlapToleranceOptions.contains(ClashDetector.defaultOverlapTolerance))
        #expect(ClashDetector.toleranceLabel(1) == "1 second")
        #expect(ClashDetector.toleranceLabel(30) == "30 seconds")
        #expect(ClashDetector.toleranceLabel(60) == "1 minute")
        #expect(ClashDetector.toleranceLabel(300) == "5 minutes")
    }

    @Test func containedMeetingIsAClash() {
        let c = ClashDetector.clashes(in: [m("outer", at: 0, for: 120), m("inner", at: 30, for: 30)], after: t0)
        #expect(c.count == 1)
        #expect(Set(c.first?.meetings.map(\.id) ?? []) == ["outer", "inner"])
        // Sharing the outer meeting's start or end still counts.
        #expect(ClashDetector.clashes(in: [m("outer", at: 0, for: 120), m("inner", at: 0, for: 30)], after: t0).count == 1)
        #expect(ClashDetector.clashes(in: [m("outer", at: 0, for: 120), m("inner", at: 90, for: 30)], after: t0).count == 1)
    }

    @Test func overlapsHelper() {
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        #expect(!ClashDetector.overlaps(at(0), at(60), at(60), at(120)))
        #expect(!ClashDetector.overlaps(at(60), at(120), at(0), at(60)))
        #expect(ClashDetector.overlaps(at(0), at(60), at(59), at(120)))
        #expect(!ClashDetector.overlaps(at(0), at(60), at(59), at(120), tolerance: 60))
        #expect(ClashDetector.overlaps(at(0), at(60), at(58), at(120), tolerance: 60))
        #expect(ClashDetector.overlaps(at(0), at(60), at(10), at(20)))
        #expect(ClashDetector.overlaps(at(10), at(20), at(0), at(60)))
    }

    @Test func pastClashesIgnored() {
        #expect(ClashDetector.clashes(in: [m("a", at: -60), m("b", at: -50)], after: t0).isEmpty)
    }

    @Test func suppression() {
        let clash = ClashDetector.clashes(in: [m("a", at: 0), m("b", at: 10)], after: t0)
        #expect(ClashDetector.suppressed(clashes: clash, choices: [clash[0].key: "b"]) == ["a"])
        #expect(ClashDetector.suppressed(clashes: clash, choices: [clash[0].key: "all"]).isEmpty)
        #expect(ClashDetector.suppressed(clashes: clash, choices: [:]).isEmpty)
    }
}

@Suite("Wrap-up and summary")
struct WrapUpTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func mt(_ id: String, _ from: Double, _ to: Double) -> Meeting {
        Meeting(id: id, title: id, start: base.addingTimeInterval(from * 60), end: base.addingTimeInterval(to * 60),
                calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray))
    }

    @Test func namesBackToBackMeeting() {
        let live = mt("live", 0, 30), next = mt("next", 30, 60), later = mt("later", 45, 90)
        let r = ReminderPlanner.wrapUps(live: [live], all: [live, next, later], minutes: 5, onlyBackToBack: false)
        #expect(r.count == 1)
        #expect(r[0].fireAt == live.end.addingTimeInterval(-300))
        #expect(r[0].joinTarget.id == "next")
        #expect(ReminderPlanner.message(for: r[0]).title == "Wrap up: next in 5 min")
        #expect(ReminderPlanner.message(for: r[0]).body.hasPrefix("live ends at "))
        // Due during the meeting, not after it ends.
        #expect(ReminderPlanner.due(r, now: base.addingTimeInterval(25 * 60 + 10), sent: []).count == 1)
        #expect(ReminderPlanner.due(r, now: base.addingTimeInterval(31 * 60), sent: []).isEmpty)
    }

    @Test func plainWrapUpAndBackToBackOnly() {
        let live = mt("live", 0, 30), gap = mt("gap", 45, 60)
        let r = ReminderPlanner.wrapUps(live: [live], all: [live, gap], minutes: 5, onlyBackToBack: false)
        #expect(r.first?.joinTarget.id == "live")
        #expect(ReminderPlanner.message(for: r[0]).title == "live ends in 5 min")
        #expect(ReminderPlanner.wrapUps(live: [live], all: [live, gap], minutes: 5, onlyBackToBack: true).isEmpty)
    }

    @Test func onlineWrapUpsNeedACall() {
        var online = mt("online", 0, 30)
        online.joinLink = MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        let inPerson = mt("room", 0, 30)
        let r = ReminderPlanner.wrapUps(live: [online, inPerson], all: [online, inPerson], minutes: 5, onlyBackToBack: false)
        #expect(r.first { $0.meeting.id == "online" }?.needsActiveCall == true)
        #expect(r.first { $0.meeting.id == "room" }?.needsActiveCall == false)
        #expect(ReminderPlanner.headsUps(for: [online], minutes: 5).first?.needsActiveCall == false)
    }

    @Test func summaryFiresLateButOnce() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: base)
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let m = Meeting(id: "a", title: "Standup", start: nine.addingTimeInterval(1800), end: nine.addingTimeInterval(2700),
                        calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray))
        let s = ReminderPlanner.morningSummary(meetings: [m], now: nine.addingTimeInterval(3600), hour: 8, minute: 30)!
        #expect(ReminderPlanner.due([s], now: nine.addingTimeInterval(3600), sent: []).count == 1)
        #expect(ReminderPlanner.due([s], now: nine.addingTimeInterval(3600), sent: [s.key]).isEmpty)
        #expect(ReminderPlanner.message(for: s).title == "Good morning — 1 meeting today")
    }
}
