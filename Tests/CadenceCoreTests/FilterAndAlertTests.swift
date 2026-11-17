import Foundation
import Testing
@testable import CadenceCore

private let cal = CalendarInfo(id: "work", title: "Work", sourceTitle: "Google", color: .gray)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(
    _ id: String = "m",
    title: String = "Standup",
    startOffset: TimeInterval = 600,
    minutes: Double = 30,
    allDay: Bool = false,
    participation: Participation = .accepted,
    availability: Availability = .busy,
    link: Bool = false
) -> Meeting {
    Meeting(
        id: id, title: title,
        start: t0.addingTimeInterval(startOffset),
        end: t0.addingTimeInterval(startOffset + minutes * 60),
        isAllDay: allDay, calendar: cal,
        participation: participation, availability: availability,
        joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil
    )
}

@Suite("Filters")
struct FilterTests {
    @Test func defaultsHideAllDayAndDeclined() {
        let f = FilterSettings()
        #expect(f.allows(meeting()))
        #expect(!f.allows(meeting(allDay: true)))
        #expect(!f.allows(meeting(participation: .declined)))
    }

    @Test func disabledCalendar() {
        var f = FilterSettings()
        f.disabledCalendarIDs = ["work"]
        #expect(!f.allows(meeting()))
    }

    @Test func keywords() {
        var f = FilterSettings()
        f.excludeKeywords = ["  LUNCH "]
        #expect(!f.allows(meeting(title: "Team lunch")))
        #expect(f.allows(meeting(title: "Planning")))
        f.includeKeywords = ["sync"]
        #expect(!f.allows(meeting(title: "Planning")))
        #expect(f.allows(meeting(title: "Design Sync")))
    }

    @Test func tentativeFreeLinkAndDuration() {
        var f = FilterSettings()
        f.hideTentative = true
        f.hideFree = true
        f.onlyWithJoinLink = true
        f.minimumDurationMinutes = 15
        #expect(!f.allows(meeting(participation: .tentative, link: true)))
        #expect(!f.allows(meeting(availability: .free, link: true)))
        #expect(!f.allows(meeting(link: false)))
        #expect(!f.allows(meeting(minutes: 10, link: true)))
        #expect(f.allows(meeting(link: true)))
    }
}

@Suite("Alert planning")
struct AlertPlannerTests {
    @Test func firesInsideLeadWindowOnce() {
        var planner = AlertPlanner()
        let m = meeting(startOffset: 30)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(-1), leadTime: 30) == nil)
        #expect(planner.due(in: [m], now: t0, leadTime: 30) == m)
        planner.markFired(m)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(5), leadTime: 30) == nil)
    }

    @Test func lateFireWithinGraceOnly() {
        let planner = AlertPlanner()
        let m = meeting(startOffset: 0)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(59), leadTime: 30) == m)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(61), leadTime: 30) == nil)
    }

    @Test func snoozeRefiresLater() {
        var planner = AlertPlanner()
        let m = meeting(startOffset: 30)
        planner.snooze(m, until: t0.addingTimeInterval(60))
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(59), leadTime: 30) == nil)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(60), leadTime: 30) == m)
        planner.markFired(m)
        #expect(planner.due(in: [m], now: t0.addingTimeInterval(90), leadTime: 30) == nil)
    }

    @Test func skipsAllDay() {
        let planner = AlertPlanner()
        #expect(planner.due(in: [meeting(startOffset: 10, allDay: true)], now: t0, leadTime: 30) == nil)
    }

    @Test func formatter() {
        #expect(CountdownFormatter.clock(30) == "0:30")
        #expect(CountdownFormatter.clock(754) == "12:34")
        #expect(CountdownFormatter.clock(3909) == "1:05:09")
        #expect(CountdownFormatter.short(45) == "45s")
        #expect(CountdownFormatter.short(61) == "2m")
        #expect(CountdownFormatter.short(3 * 3600 + 20 * 60) == "3h 20m")
    }
}
