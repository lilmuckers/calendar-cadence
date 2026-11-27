import CadenceCore
import Foundation
import Testing
@testable import Cadence

// iPhone-only logic. The shared CadenceCore suite (Tests/CadenceCoreTests) also runs in this
// bundle, so the core is checked on iOS as well as on the Mac.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(link: Bool = false, location: String? = nil, attendees: Int = 0) -> Meeting {
    Meeting(id: "a", title: "Design Review", start: now, end: now.addingTimeInterval(1800),
            calendar: CalendarInfo(id: "c", title: "Work", sourceTitle: "Google", color: .gray, kind: .google),
            location: location, attendeeCount: attendees,
            joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil)
}

@Suite("Phone preferences")
struct PhonePrefsTests {
    @Test func roundTrips() throws {
        var prefs = PhonePrefs()
        prefs.wrapUpEnabled = true
        prefs.takeoverLeadSeconds = 90
        prefs.liveActivityLeadMinutes = 10
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(PhonePrefs.self, from: data) == prefs)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(PhonePrefs.self, from: Data(#"{"headsUpMinutes": 2}"#.utf8))
        var expected = PhonePrefs()
        expected.headsUpMinutes = 2
        #expect(decoded == expected)
    }

    @Test func wrongTypesFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(PhonePrefs.self, from: Data(#"{"alertSound": "loud", "wrapUpMinutes": 3}"#.utf8))
        #expect(decoded.alertSound == PhonePrefs().alertSound)
        #expect(decoded.wrapUpMinutes == 3)
    }

    @Test func wrapUpsAreOffByDefault() {
        // The phone can't tell whether you're still on a call, so it doesn't nag unless asked.
        #expect(PhonePrefs().wrapUpEnabled == false)
    }
}

@Suite("Phone theme")
struct ThemeTests {
    @Test func detailPrefersTheServiceAndCountsPeople() {
        #expect(Theme.detail(meeting(link: true, location: "Room 4", attendees: 6)) == "Zoom · 6 people")
    }

    @Test func detailFallsBackToPlaceThenCalendar() {
        #expect(Theme.detail(meeting(location: "Room 4")) == "Room 4")
        #expect(Theme.detail(meeting()) == "Work")
    }

    @Test func allDayRange() {
        var m = meeting()
        m.isAllDay = true
        #expect(Theme.range(m) == "All day")
    }
}

@Suite("Paired Mac nickname")
struct PairedMacTests {
    @Test func oldSavedMacStillDecodes() throws {
        let json = #"{"id":"m1","name":"C02XK1ABCDEF","hosts":["192.168.0.21"],"port":62166}"#
        let mac = try JSONDecoder().decode(PairedMac.self, from: Data(json.utf8))
        #expect(mac.nickname == nil)
        #expect(mac.displayName == "C02XK1ABCDEF")
    }

    @Test func oldSingleAddressMigratesIntoTheBook() {
        let mac = PairedMac(id: "m1", name: "Mac", hosts: ["192.168.0.21"], port: 62166)
        #expect(mac.directAddresses.map(\.host) == ["192.168.0.21"])
        #expect(mac.book().entries.count == 1)
    }

    @Test func nicknameWinsAndRoundTrips() throws {
        let mac = PairedMac(id: "m1", name: "C02XK1ABCDEF", nickname: "Work laptop")
        #expect(mac.displayName == "Work laptop")
        let back = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(mac))
        #expect(back == mac)
    }
}

@Suite("Widget schedule")
struct WidgetScheduleTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 10:00 UTC on the test day.
    private var morning: Date { cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)! }

    private func item(_ id: String, inMinutes: Double, length: Double = 30) -> WidgetMeeting {
        let start = morning.addingTimeInterval(inMinutes * 60)
        return WidgetMeeting(id: id, title: id, start: start, end: start.addingTimeInterval(length * 60),
                             red: 0.2, green: 0.4, blue: 0.8, hasLink: false)
    }

    @Test func nextIsTheNextToStartToday() {
        let schedule = WidgetSchedule(meetings: [item("started", inMinutes: -10), item("later", inMinutes: 90),
                                                 item("soon", inMinutes: 20), item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        #expect(schedule.next(after: morning, calendar: cal)?.id == "soon")
        #expect(schedule.following(schedule.next(after: morning, calendar: cal)!, calendar: cal)?.id == "later")
    }

    @Test func nothingLeftTodayMeansNoNext() {
        let schedule = WidgetSchedule(meetings: [item("started", inMinutes: -10), item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        #expect(schedule.next(after: morning, calendar: cal) == nil)
        #expect(schedule.mood(at: morning, calendar: cal) == .calm)
    }

    @Test func moodFollowsTheNextMeeting() {
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 20)], generatedAt: morning)
        #expect(schedule.mood(at: morning, calendar: cal) == .calm)
        #expect(schedule.mood(at: morning.addingTimeInterval(10 * 60), calendar: cal) == .nervous)
        #expect(schedule.mood(at: morning.addingTimeInterval(17 * 60), calendar: cal) == .panicking)
    }

    @Test func entryDatesCoverStartsMoodsAndMidnight() {
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 10), item("later", inMinutes: 60),
                                                 item("tomorrow", inMinutes: 18 * 60)],
                                      generatedAt: morning)
        let dates = schedule.entryDates(from: morning, calendar: cal)
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: morning))!
        let m = { (minutes: Double) in morning.addingTimeInterval(minutes * 60) }
        // "soon" is already inside its nervous lead, so only its panic point and start count.
        // Ends (40, 90) and the next one's 10-minute takeover (50) redraw for the live view.
        // Tomorrow's 04:00 one (+1080) gets the same, and the timeline runs on to the end of tomorrow.
        let horizon = cal.date(byAdding: .day, value: 1, to: midnight)!
        #expect(dates == [morning, m(5), m(10), m(40), m(45), m(50), m(55), m(60), m(90), midnight,
                          m(1065), m(1070), m(1075), m(1080), m(1110), horizon])
    }

    /// What the widget shows at `t` from a timeline built at `built`: WidgetKit keeps the last entry
    /// dated at or before `t` until it's given a new timeline.
    private func shown(at t: Date, builtAt built: Date, _ schedule: WidgetSchedule) -> (live: String?, next: String?) {
        let entry = schedule.entryDates(from: built, calendar: cal).last { $0 <= t } ?? built
        return (schedule.live(at: entry, calendar: cal)?.id, schedule.next(after: entry, calendar: cal)?.id)
    }

    /// Issue #102: the lock screen widget got the first meeting of the day wrong. A timeline built the
    /// evening before stopped at midnight, so with iOS holding reloads back overnight the whole
    /// morning played out on that one entry. It now carries on through tomorrow by itself.
    @Test func anEveningTimelineCarriesTheWidgetThroughTomorrowMorning() {
        // morning is 10:00; tomorrow 09:30 is +1410 min, 10:30 is +1470.
        var schedule = WidgetSchedule(meetings: [item("today", inMinutes: 60), item("standup", inMinutes: 1410),
                                                 item("review", inMinutes: 1470)],
                                      generatedAt: morning)
        schedule.tomorrowFromHour = 18
        let built = morning.addingTimeInterval(600 * 60) // 20:00, the last reload iOS allowed
        let m = { (minutes: Double) in morning.addingTimeInterval(minutes * 60) }
        let dates = schedule.entryDates(from: built, calendar: cal)
        for d in [m(1395), m(1400), m(1405), m(1410), m(1440), m(1460), m(1470)] { #expect(dates.contains(d)) }
        #expect(schedule.tomorrowFirst(after: built, calendar: cal)?.id == "standup")
        #expect(shown(at: m(1380), builtAt: built, schedule).next == "standup") // 09:00
        #expect(shown(at: m(1408), builtAt: built, schedule).next == "standup") // 09:28
        // 09:35: in the standup, with the review as "then".
        #expect(shown(at: m(1415), builtAt: built, schedule).live == "standup")
        #expect(shown(at: m(1415), builtAt: built, schedule).next == "review")
        // 10:05: the standup's over, the review is next.
        #expect(shown(at: m(1445), builtAt: built, schedule).live == nil)
        #expect(shown(at: m(1445), builtAt: built, schedule).next == "review")
    }

    @Test func tomorrowsMomentsAndCutoffAreInTheTimeline() {
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: morning))!
        let beforeWork = WidgetSegment(kind: "beforeWork", start: tomorrowStart.addingTimeInterval(6 * 3600),
                                       end: tomorrowStart.addingTimeInterval(9 * 3600), title: "Morning!", detail: "")
        var schedule = WidgetSchedule(meetings: [], generatedAt: morning, segments: [beforeWork])
        schedule.tomorrowFromHour = 20
        let dates = schedule.entryDates(from: morning, calendar: cal)
        #expect(dates.contains(beforeWork.start))
        #expect(dates.contains(beforeWork.end))
        #expect(dates.contains(tomorrowStart.addingTimeInterval(20 * 3600))) // tomorrow's evening cutoff
        let horizon = cal.date(byAdding: .day, value: 1, to: tomorrowStart)!
        #expect(dates.allSatisfy { $0 >= morning && $0 <= horizon })
    }

    @Test func aMeetingInProgressShowsUntilTheNextIsClose() {
        // Live 09:00–09:30, next 09:30: the live one shows until 09:20, as in the app.
        let schedule = WidgetSchedule(meetings: [item("live", inMinutes: -10), item("next", inMinutes: 20)],
                                      generatedAt: morning)
        #expect(schedule.live(at: morning, calendar: cal)?.id == "live")
        #expect(schedule.next(after: morning, calendar: cal)?.id == "next")
        #expect(schedule.live(at: morning.addingTimeInterval(10 * 60), calendar: cal) == nil)
        #expect(schedule.entryDates(from: morning, calendar: cal).contains(morning.addingTimeInterval(10 * 60)))
        // With nothing else today it shows until it ends.
        let alone = WidgetSchedule(meetings: [item("live", inMinutes: -10)], generatedAt: morning)
        #expect(alone.live(at: morning, calendar: cal)?.id == "live")
        #expect(alone.live(at: morning.addingTimeInterval(20 * 60), calendar: cal) == nil)
    }

    @Test func tomorrowsFirstShowsFromTheCutoffOnceTodayIsDone() {
        // morning is 10:00; cutoff 20:00 is +600 min. Tomorrow 09:00 is +1380, 11:00 is +1500.
        var schedule = WidgetSchedule(meetings: [item("today", inMinutes: 60), item("tomorrowLate", inMinutes: 1500),
                                                 item("tomorrowEarly", inMinutes: 1380)],
                                      generatedAt: morning)
        let evening = morning.addingTimeInterval(600 * 60)
        #expect(schedule.tomorrowFirst(after: evening, calendar: cal) == nil) // off by default
        schedule.tomorrowFromHour = 20
        #expect(schedule.tomorrowFirst(after: morning, calendar: cal) == nil) // "today" still to come
        #expect(schedule.tomorrowFirst(after: evening.addingTimeInterval(-60), calendar: cal) == nil) // 19:59
        #expect(schedule.tomorrowFirst(after: evening, calendar: cal)?.id == "tomorrowEarly")
        #expect(schedule.entryDates(from: morning, calendar: cal).contains(evening))
    }

    @Test func aLateMeetingTodayStillWinsAfterTheCutoff() {
        var schedule = WidgetSchedule(meetings: [item("lateToday", inMinutes: 660), item("tomorrow", inMinutes: 1380)],
                                      generatedAt: morning)
        schedule.tomorrowFromHour = 20
        let evening = morning.addingTimeInterval(600 * 60)
        #expect(schedule.next(after: evening, calendar: cal)?.id == "lateToday")
        #expect(schedule.tomorrowFirst(after: evening, calendar: cal) == nil)
    }

    @Test func oldSchedulesWithoutTheCutoffStillDecode() throws {
        let json = #"{"meetings":[],"generatedAt":0}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(WidgetSchedule.self, from: json).tomorrowFromHour == nil)
    }

    @Test func momentYieldsToMeetings() {
        let focus = WidgetSegment(kind: "focus", start: morning, end: morning.addingTimeInterval(7200), title: "Focus time", detail: "")
        var schedule = WidgetSchedule(meetings: [item("review", inMinutes: 120)], generatedAt: morning, segments: [focus])
        #expect(schedule.segment(at: morning.addingTimeInterval(600))?.pose == .focus)
        // Within half an hour of the meeting, the meeting wins.
        #expect(schedule.segment(at: morning.addingTimeInterval(100 * 60)) == nil)
        // Its yield time and the segment's end are timeline entries.
        let dates = schedule.entryDates(from: morning, calendar: cal)
        #expect(dates.contains(morning.addingTimeInterval(90 * 60)))
        #expect(dates.contains(focus.end))
        schedule.segments = nil
        #expect(schedule.segment(at: morning.addingTimeInterval(600)) == nil)
        #expect(WidgetSegment(kind: "meal", start: morning, end: morning, title: "", detail: "").pose == .lunch)
    }

    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "WidgetScheduleTests"))
        defer { defaults.removePersistentDomain(forName: "WidgetScheduleTests") }
        let schedule = WidgetSchedule(meetings: [item("soon", inMinutes: 10)], generatedAt: morning)
        schedule.save(to: defaults)
        #expect(WidgetSchedule.load(from: defaults) == schedule)
    }
}

@Suite("Live Activity: missed meetings")
@MainActor
struct MissedActivityTests {
    private func state(start: Date, missedUntil: Date?, showsMissed: Bool? = nil) -> MeetingActivityAttributes.ContentState {
        MeetingActivityAttributes.ContentState(
            meetingID: "a", title: "Design Review", start: start, end: start.addingTimeInterval(1800), live: false,
            calendarTitle: "Work", hasLink: true, red: 0.3, green: 0.5, blue: 0.9,
            countdownFrom: start.addingTimeInterval(-1800), mood: .calm,
            missedUntil: missedUntil, showsMissed: showsMissed)
    }

    @Test func turnsMissedAtTheStartThenGoes() {
        let s = state(start: now, missedUntil: now.addingTimeInterval(300), showsMissed: true)
        #expect(!s.missed(now: now.addingTimeInterval(-1)))
        #expect(s.missed(now: now.addingTimeInterval(60)))
        #expect(s.mood(now: now.addingTimeInterval(60)) == .panicking)
        #expect(s.gone(now: now.addingTimeInterval(300)))
        #expect(!s.missed(now: now.addingTimeInterval(300)))
        #expect(s.mood(now: now.addingTimeInterval(300)) == .disappointed)
        #expect(state(start: now, missedUntil: now).mood(now: now.addingTimeInterval(1)) == .calm)
    }

    @Test func withoutALinkNothingIsMissed() {
        let s = state(start: now, missedUntil: nil)
        #expect(!s.missed(now: now.addingTimeInterval(60)))
        #expect(!s.gone(now: now.addingTimeInterval(3600)))
    }

    @Test func staleAtTheStartThenWhenTheMissedTimeIsUp() {
        let s = state(start: now, missedUntil: now.addingTimeInterval(300))
        #expect(LiveActivityController.staleDate(for: s, now: now.addingTimeInterval(-600)) == now)
        #expect(LiveActivityController.staleDate(for: s, now: now.addingTimeInterval(60)) == now.addingTimeInterval(300))
    }

    @Test func missedSettingsDefaultAndDecode() throws {
        let decoded = try JSONDecoder().decode(PhonePrefs.self, from: Data(#"{"liveActivityMissedLinger": 2}"#.utf8))
        #expect(decoded.liveActivityMissedLinger == .twoMinutes)
        #expect(decoded.liveActivityShowsMissed == false)
        #expect(PhonePrefs().liveActivityMissedLinger == .fiveMinutes)
    }
}
