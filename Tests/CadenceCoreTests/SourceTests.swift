import Foundation
import Testing
@testable import CadenceCore

private let cal = CalendarInfo(id: "feed", title: "Feed", sourceTitle: "ICS", color: .gray)
private let london = TimeZone(identifier: "Europe/London")!

private func date(_ s: String, tz: TimeZone = london) -> Date {
    ICSParser.parseDate(s, tz: tz)!.date
}

private func window(_ from: String, _ to: String) -> Range<Date> { date(from)..<date(to) }

@Suite("ICS parsing")
struct ICSParserTests {
    static let sample = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:abc-1\r
    SUMMARY:Design review\\, round 2\r
    DTSTART;TZID=Europe/London:20261117T100000\r
    DTEND;TZID=Europe/London:20261117T110000\r
    LOCATION:Room 4\r
    DESCRIPTION:Join: https://meet.google.com/abc-defg-hij\\nThanks\r
    ATTENDEE;CN="Doe, Jane":mailto:jane@example.com\r
    ATTENDEE:mailto:bob@example.com\r
    ORGANIZER;CN=Ann:mailto:ann@example.com\r
    BEGIN:VALARM\r
    TRIGGER:-PT10M\r
    DESCRIPTION:Reminder\r
    END:VALARM\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:allday\r
    SUMMARY:Holiday\r
    DTSTART;VALUE=DATE:20261118\r
    DTEND;VALUE=DATE:20261119\r
    TRANSP:TRANSPARENT\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:utc\r
    SUMMARY:Long title that is folded
     across lines\r
    DTSTART:20261117T150000Z\r
    DURATION:PT45M\r
    STATUS:CANCELLED\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @Test func parsesEvents() {
        let events = ICSParser.parse(Self.sample)
        #expect(events.count == 3)
        let e = events[0]
        #expect(e.summary == "Design review, round 2")
        #expect(e.start == date("20261117T100000"))
        #expect(e.end.timeIntervalSince(e.start) == 3600)
        #expect(e.location == "Room 4")
        #expect(e.description == "Join: https://meet.google.com/abc-defg-hij\nThanks")
        #expect(e.attendeeCount == 2)
        #expect(e.organizer == "Ann")
        #expect(events[1].isAllDay)
        #expect(events[1].transparent)
        #expect(events[2].summary == "Long title that is foldedacross lines")
        #expect(events[2].end.timeIntervalSince(events[2].start) == 45 * 60)
    }

    @Test func toMeetings() {
        let meetings = ICSParser.meetings(from: ICSParser.parse(Self.sample), calendar: cal,
                                          window: window("20261117T000000", "20261119T000000"))
        #expect(meetings.count == 3)
        #expect(meetings.first { $0.title.hasPrefix("Design") }?.joinLink?.service == .googleMeet)
        #expect(meetings.first { $0.title == "Holiday" }?.availability == .free)
        #expect(meetings.first { $0.title.hasPrefix("Long") }?.isCanceled == true)
    }

    @Test func windowsTimeZoneAndDuration() {
        #expect(ICSParser.timeZone(for: "Pacific Standard Time")?.identifier == "America/Los_Angeles")
        #expect(ICSParser.timeZone(for: "\"Europe/Paris\"")?.identifier == "Europe/Paris")
        #expect(ICSParser.parseDuration("P1DT2H") == 93_600)
        #expect(ICSParser.parseDuration("-PT15M") == -900)
    }
}

@Suite("Recurrence")
struct RecurrenceTests {
    private func occ(_ rule: String, start: String, from: String, to: String) -> [Date] {
        RecurrenceRule(rule, timeZone: london)!
            .occurrences(start: date(start), duration: 1800, timeZone: london, window: window(from, to))
    }

    @Test func weeklyByDay() {
        // Mon/Wed standup starting Mon 2 Nov 2026
        let r = occ("FREQ=WEEKLY;BYDAY=MO,WE", start: "20261102T093000", from: "20261116T000000", to: "20261122T000000")
        #expect(r == [date("20261116T093000"), date("20261118T093000")])
    }

    @Test func dailyCountStopsEarly() {
        let r = occ("FREQ=DAILY;COUNT=3", start: "20261115T090000", from: "20261115T000000", to: "20261130T000000")
        #expect(r.count == 3)
    }

    @Test func untilIsInclusive() {
        let r = occ("FREQ=DAILY;UNTIL=20261117T090000Z", start: "20261115T090000", from: "20261101T000000", to: "20261130T000000")
        #expect(r.last == date("20261117T090000"))
    }

    @Test func monthlyLastFriday() {
        let r = occ("FREQ=MONTHLY;BYDAY=-1FR", start: "20260130T160000", from: "20261101T000000", to: "20261201T000000")
        #expect(r == [date("20261127T160000")])
    }

    @Test func biweeklyInterval() {
        let r = occ("FREQ=WEEKLY;INTERVAL=2", start: "20261103T100000", from: "20261101T000000", to: "20261201T000000")
        #expect(r == [date("20261103T100000"), date("20261117T100000")])
    }

    @Test func keepsWallClockAcrossDST() {
        // UK clocks go back 25 Oct 2026; a 09:00 daily stays at 09:00 local.
        let r = occ("FREQ=DAILY", start: "20261020T090000", from: "20261026T000000", to: "20261027T000000")
        let hour = Calendar.current.dateComponents(in: london, from: r[0]).hour
        #expect(hour == 9)
    }

    @Test func exdateAndOverride() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:r1
        SUMMARY:Sync
        DTSTART;TZID=Europe/London:20261116T100000
        DTEND;TZID=Europe/London:20261116T103000
        RRULE:FREQ=DAILY;COUNT=4
        EXDATE;TZID=Europe/London:20261117T100000
        END:VEVENT
        BEGIN:VEVENT
        UID:r1
        RECURRENCE-ID;TZID=Europe/London:20261118T100000
        SUMMARY:Sync (moved)
        DTSTART;TZID=Europe/London:20261118T140000
        DTEND;TZID=Europe/London:20261118T143000
        END:VEVENT
        END:VCALENDAR
        """
        let m = ICSParser.meetings(from: ICSParser.parse(ics), calendar: cal, window: window("20261116T000000", "20261120T000000"))
            .sorted { $0.start < $1.start }
        #expect(m.map(\.title) == ["Sync", "Sync (moved)", "Sync"])
        #expect(m[1].start == date("20261118T140000"))
    }
}

@Suite("Google mapping")
struct GoogleMapperTests {
    @Test func mapsEvent() throws {
        let json = """
        {"items":[{"id":"e1","status":"confirmed","summary":"Planning",
          "start":{"dateTime":"2026-11-17T10:00:00Z"},"end":{"dateTime":"2026-11-17T10:30:00Z"},
          "hangoutLink":"https://meet.google.com/abc-defg-hij",
          "attendees":[{"email":"me@x.com","self":true,"responseStatus":"tentative"},{"email":"b@x.com"}],
          "organizer":{"email":"boss@x.com","displayName":"Boss"}},
         {"id":"wl","eventType":"workingLocation","start":{"date":"2026-11-17"},"end":{"date":"2026-11-18"}}]}
        """
        let list = try JSONDecoder().decode(GoogleEventList.self, from: Data(json.utf8))
        let gcal = CalendarInfo(id: "me@x.com", title: "Me", sourceTitle: "Google", color: GoogleMapper.color(hex: "#a4bdfc"))
        let meetings = (list.items ?? []).compactMap { GoogleMapper.meeting($0, calendar: gcal) }
        #expect(meetings.count == 1)
        let m = meetings[0]
        #expect(m.joinLink?.service == .googleMeet)
        #expect(m.participation == .tentative)
        #expect(m.attendeeCount == 2)
        #expect(m.organizer == "Boss")
        #expect(m.duration == 1800)
        #expect(abs(gcal.color.blue - 252.0 / 255) < 0.001)
    }
}

@Suite("Deduplication")
struct DedupTests {
    private func m(_ id: String, _ title: String, link: Bool = false, cal: String = "a") -> Meeting {
        Meeting(id: id, title: title, start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2800),
                calendar: CalendarInfo(id: cal, title: cal, sourceTitle: "s", color: .gray),
                joinLink: link ? MeetingLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil)
    }

    @Test func collapsesCopiesKeepingTheRichest() {
        let out = MeetingDeduplicator.dedupe([m("1", "Weekly  Sync"), m("2", "Fwd: weekly sync", link: true, cal: "b"), m("3", "Other")])
        #expect(out.count == 2)
        #expect(out[0].joinLink != nil)
    }

    @Test func differentTitlesSameLinkAreSame() {
        #expect(MeetingDeduplicator.isSameMeeting(m("1", "A", link: true), m("2", "B", link: true)))
        #expect(!MeetingDeduplicator.isSameMeeting(m("1", "A"), m("2", "B")))
    }
}

@Suite("JWT")
struct JWTTests {
    @Test func readsEmailClaim() {
        // {"alg":"none"} . {"email":"me@example.com","sub":"1"} . (no signature)
        let token = "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6Im1lQGV4YW1wbGUuY29tIiwic3ViIjoiMSJ9."
        #expect(JWT.email(in: token) == "me@example.com")
        #expect(JWT.email(in: "garbage") == nil)
    }
}
