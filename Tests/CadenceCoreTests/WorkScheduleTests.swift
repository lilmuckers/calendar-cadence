import Foundation
import Testing
@testable import CadenceCore

/// A Wednesday, so it's a working day under the default schedule.
private let cal = Calendar.current
private let wednesday: Date = {
    var d = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    while cal.component(.weekday, from: d) != 4 { d = cal.date(byAdding: .day, value: 1, to: d)! }
    return d
}()

private func at(_ h: Double, _ day: Date = wednesday) -> Date { day.addingTimeInterval(h * 3600) }

private func m(_ id: String, _ from: Double, _ to: Double, day: Date = wednesday, availability: Availability = .busy) -> Meeting {
    Meeting(id: id, title: id, start: at(from, day), end: at(to, day),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "s", color: .gray), availability: availability)
}

@Suite("Working hours")
struct WorkScheduleTests {
    let schedule = WorkSchedule()

    @Test func defaultsAreWeekdaysWithLunch() {
        #expect(schedule.hours(on: wednesday)?.start == at(9))
        #expect(schedule.hours(on: wednesday)?.end == at(17.5))
        let saturday = cal.date(byAdding: .day, value: 3, to: wednesday)!
        #expect(schedule.hours(on: saturday) == nil)
        #expect(schedule.breaks(on: saturday).isEmpty)
        #expect(schedule.breaks(on: wednesday).map(\.1.start) == [at(12.5)])
    }

    @Test func decodesPartialAndPadsDays() throws {
        let json = #"{"days":[{"enabled":false,"start":0,"end":0}],"breaks":[]}"#
        let s = try JSONDecoder().decode(WorkSchedule.self, from: Data(json.utf8))
        #expect(s.days.count == 7)
        #expect(s.breaks.isEmpty)
        #expect(s.defences.clashPrompt)
        #expect(s.focusMinimumMinutes == 45)
    }

    @Test func breaksOnChosenDaysOnly() {
        var s = schedule
        s.breaks = [WorkBreak(id: "walk", name: "Walk", start: 15 * 60, end: 15 * 60 + 30, days: [2])]
        #expect(s.breaks(on: wednesday).isEmpty)
        let monday = cal.date(byAdding: .day, value: -2, to: wednesday)!
        #expect(s.breaks(on: monday).count == 1)
    }

    @Test func conflicts() {
        #expect(schedule.conflicts(for: m("lunchy", 12, 13)) == [.onBreak("Lunch")])
        #expect(schedule.conflicts(for: m("late", 17, 18)) == [.outsideHours])
        #expect(schedule.conflicts(for: m("fine", 10, 11)).isEmpty)
        let sunday = cal.date(byAdding: .day, value: 4, to: wednesday)!
        #expect(schedule.conflicts(for: m("sun", 10, 11, day: sunday)) == [.dayOff])
        #expect(WorkConflict.onBreak("Lunch").label == "Lands on your Lunch break")
    }

    @Test func momentsThroughTheDay() {
        let meetings = [m("standup", 9.5, 9.75), m("review", 14, 15)]
        func moment(_ h: Double) -> DayMoment? { DayPlanner.moment(meetings: meetings, schedule: schedule, now: at(h)) }
        if case .beforeWork(let starts, let first) = moment(8) { #expect(starts == at(9)); #expect(first?.id == "standup") } else { Issue.record("before work") }
        if case .inMeeting(let live) = moment(9.6) { #expect(live.id == "standup") } else { Issue.record("in meeting") }
        if case .focus(let since, let until, let next) = moment(10) {
            #expect(since == at(9.75)); #expect(until == at(12.5)); #expect(next == nil)
        } else { Issue.record("focus before lunch") }
        if case .onBreak(let b, let ends) = moment(13) { #expect(b.name == "Lunch"); #expect(ends == at(13.5)) } else { Issue.record("lunch") }
        // 13:30–14:00 is too short to count as focus.
        if case .between(let until) = moment(13.6) { #expect(until == at(14)) } else { Issue.record("between") }
        if case .focus(_, let until, _) = moment(15.5) { #expect(until == at(17.5)) } else { Issue.record("afternoon focus") }
        if case .endOfDay(let recap) = moment(18) {
            #expect(recap.meetingCount == 2)
            #expect(recap.meetingMinutes == 75)
            // 9:45–12:30 (165) and 15:00–17:30 (150); 13:30–14:00 is too short.
            #expect(recap.focusMinutes == 315)
            #expect(recap.longestFocusMinutes == 165)
        } else { Issue.record("end of day") }
        // 9:45–12:30 done, plus half an hour into the afternoon stretch.
        #expect(DayPlanner.focusSoFar(meetings: meetings, schedule: schedule, now: at(15.5)) == 195)
        #expect(DayPlanner.focusSoFar(meetings: meetings, schedule: schedule, now: at(8)) == 0)
        var off = schedule
        off.enabled = false
        #expect(DayPlanner.moment(meetings: meetings, schedule: off, now: at(10)) == nil)
    }

    @Test func focusEndsAtNextMeeting() {
        let meetings = [m("review", 11, 12)]
        if case .focus(_, let until, let next) = DayPlanner.moment(meetings: meetings, schedule: schedule, now: at(9.5)) {
            #expect(until == at(11)); #expect(next?.id == "review")
        } else { Issue.record("focus") }
        let msg = DayPlanner.message(for: .endOfDay(DayRecap(meetingCount: 4, meetingMinutes: 200, focusMinutes: 130, longestFocusMinutes: 90)), now: at(18))
        #expect(msg.detail == "4 meetings · you got 2h 10m of focus time!")
    }

    @Test func segmentsLayOutTheDay() {
        let meetings = [m("standup", 9.5, 9.75), m("review", 14, 15)]
        let segs = DayPlanner.segments(meetings: meetings, schedule: schedule, day: wednesday)
        #expect(segs.map(\.kind) == [.beforeWork, .focus, .meal, .focus, .endOfDay])
        #expect(segs[0].start == at(6))
        #expect(segs[1].start == at(9.75))
        #expect(segs[1].end == at(12.5))
        #expect(segs[3].start == at(15))
        #expect(segs[4].detail.contains("focus time"))
        let saturday = cal.date(byAdding: .day, value: 3, to: wednesday)!
        #expect(DayPlanner.segments(meetings: [], schedule: schedule, day: saturday).isEmpty)
        // A break given up for the day isn't one.
        let lunch = schedule.breakMeetings(from: wednesday, to: at(24))[0]
        #expect(!DayPlanner.segments(meetings: meetings, schedule: schedule, day: wednesday, skipping: [lunch.id]).contains { $0.kind == .meal })
    }

    @Test func freeTimeSkipsBreaksAndDaysOff() {
        let from = wednesday, to = cal.date(byAdding: .day, value: 7, to: wednesday)!
        let slots = FreeTimeFinder.slots(meetings: [m("a", 10, 11)], from: from, to: to, minDuration: 30 * 60, schedule: schedule)
        let today = slots.filter { cal.isDate($0.start, inSameDayAs: wednesday) }
        #expect(today.map(\.start) == [at(9), at(11), at(13.5)])
        #expect(today[1].end == at(12.5))
        // Five working days in the week.
        #expect(Set(slots.map { cal.startOfDay(for: $0.start) }).count == 5)

        var open = schedule
        open.defences.protectInFreeTime = false
        let unprotected = FreeTimeFinder.slots(meetings: [], from: from, to: at(24), minDuration: 30 * 60, schedule: open)
        #expect(unprotected.map(\.start) == [at(9)])
        let custom = FreeTimeFinder.slots(meetings: [], from: from, to: at(24), minDuration: 30 * 60, schedule: schedule, hours: (8 * 60, 12 * 60))
        #expect(custom.map(\.end) == [at(12)])
    }

    @Test func breakNudgesAndOverrun() {
        let breaks = schedule.breakMeetings(from: wednesday, to: at(24))
        #expect(breaks.count == 1)
        #expect(breaks[0].isBreak)
        let running = m("workshop", 11, 13)
        let r = ReminderPlanner.breakNudges(breaks: breaks, meetings: [running, m("short", 12.45, 12.6)], nudge: true, overrun: true)
        #expect(r.count == 2)
        let overrun = r.first { if case .breakOverrun = $0.kind { true } else { false } }!
        #expect(overrun.meeting.id == "workshop")
        #expect(overrun.fireAt == at(12.5).addingTimeInterval(-300))
        #expect(ReminderPlanner.due(r, now: at(12.5), sent: []).map(\.key) == ["break:\(breaks[0].id)"])
        #expect(ReminderPlanner.message(for: overrun).title == "Lunch starts in 5 min")
        #expect(CompanionReminder(overrun).joinMeetingID == nil)
        #expect(ReminderPlanner.breakNudges(breaks: breaks, meetings: [running], nudge: false, overrun: false).isEmpty)
    }

    @Test func breaksClashWithMeetings() {
        let breaks = schedule.breakMeetings(from: wednesday, to: at(24))
        let clashes = ClashDetector.clashes(in: ([m("lunch-and-learn", 12.5, 13.5)] + breaks).sorted { $0.start < $1.start }, after: at(8))
        #expect(clashes.count == 1)
        #expect(clashes[0].meetings.contains { $0.isBreak })
    }

    @Test func snapshotCarriesSchedule() throws {
        let snap = CompanionSnapshot(macName: "Mac", generatedAt: wednesday, meetings: [], workSchedule: schedule)
        let data = try CompanionFraming.encode(.snapshot(snap))
        let back = try CompanionFraming.decodeBody(data.dropFirst(4))
        #expect(back == .snapshot(snap))
    }
}
