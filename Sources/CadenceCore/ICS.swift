import Foundation

/// One VEVENT from an iCalendar feed, before recurrence expansion.
public struct ICSEvent: Equatable, Sendable {
    public var uid: String
    public var summary: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone
    public var location: String?
    public var description: String?
    public var url: URL?
    public var status: String?
    public var transparent: Bool
    public var organizer: String?
    public var organizerEmail: String? = nil
    public var attendeeCount: Int
    public var attendees: [Attendee] = []
    public var rrule: RecurrenceRule?
    public var exdates: [Date]
    /// Set on an override of one occurrence of a recurring event.
    public var recurrenceID: Date?
    /// RFC 7986 COLOR.
    public var color: RGBAColor? = nil
}

/// Subset of RFC 5545 RRULE that real-world calendars use.
public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    /// A weekday with an optional ordinal: 2TU = second Tuesday, -1FR = last Friday.
    public struct Day: Equatable, Sendable {
        public var weekday: Int // 1 = Sunday … 7 = Saturday (Calendar convention)
        public var ordinal: Int?
    }

    public var frequency: Frequency
    public var interval = 1
    public var count: Int?
    public var until: Date?
    public var byDay: [Day] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []
    public var weekStart = 2 // Monday

    public init(frequency: Frequency) { self.frequency = frequency }

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    public init?(_ text: String, timeZone: TimeZone) {
        var parts: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        guard let f = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        frequency = f
        interval = parts["INTERVAL"].flatMap(Int.init) ?? 1
        count = parts["COUNT"].flatMap(Int.init)
        until = parts["UNTIL"].flatMap { ICSParser.parseDate($0, tz: timeZone)?.date }
        byMonthDay = parts["BYMONTHDAY"]?.split(separator: ",").compactMap { Int($0) } ?? []
        byMonth = parts["BYMONTH"]?.split(separator: ",").compactMap { Int($0) } ?? []
        weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 2
        byDay = parts["BYDAY"]?.split(separator: ",").compactMap { token in
            let t = token.uppercased()
            guard t.count >= 2, let wd = Self.weekdays[String(t.suffix(2))] else { return nil }
            let prefix = t.dropLast(2)
            return Day(weekday: wd, ordinal: prefix.isEmpty ? nil : Int(prefix))
        } ?? []
    }

    /// Occurrence start times overlapping the window. Expands from the first occurrence so COUNT is honoured.
    public func occurrences(start: Date, duration: TimeInterval, timeZone: TimeZone, window: Range<Date>) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = weekStart
        let time = cal.dateComponents([.hour, .minute, .second], from: start)
        let step = max(1, interval)
        var results: [Date] = []
        var emitted = 0

        func atStartTime(_ day: Date) -> Date? {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = time.hour; c.minute = time.minute; c.second = time.second
            return cal.date(from: c)
        }

        for period in 0..<5000 {
            let candidates: [Date]
            switch frequency {
            case .daily:
                guard let d = cal.date(byAdding: .day, value: period * step, to: start) else { return results }
                let ok = (byDay.isEmpty || byDay.contains { $0.weekday == cal.component(.weekday, from: d) })
                    && (byMonth.isEmpty || byMonth.contains(cal.component(.month, from: d)))
                candidates = ok ? [d] : []
            case .weekly:
                guard let anchor = cal.date(byAdding: .weekOfYear, value: period * step, to: start),
                      let week = cal.dateInterval(of: .weekOfYear, for: anchor) else { return results }
                let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.map(\.weekday)
                candidates = (0..<7).compactMap { offset -> Date? in
                    guard let d = cal.date(byAdding: .day, value: offset, to: week.start),
                          days.contains(cal.component(.weekday, from: d)) else { return nil }
                    return atStartTime(d)
                }
            case .monthly:
                guard let anchor = cal.date(byAdding: .month, value: period * step, to: cal.date(from: cal.dateComponents([.year, .month], from: start))!) else { return results }
                candidates = daysInMonth(anchor, cal: cal, defaultDay: cal.component(.day, from: start)).compactMap(atStartTime)
            case .yearly:
                let startYear = cal.component(.year, from: start)
                let months = byMonth.isEmpty ? [cal.component(.month, from: start)] : byMonth
                candidates = months.sorted().flatMap { month -> [Date] in
                    guard let first = cal.date(from: DateComponents(year: startYear + period * step, month: month, day: 1)) else { return [] }
                    return daysInMonth(first, cal: cal, defaultDay: cal.component(.day, from: start)).compactMap(atStartTime)
                }
            }

            for date in candidates.sorted() where date >= start {
                if let until, date > until { return results }
                if let count, emitted >= count { return results }
                emitted += 1
                if date >= window.upperBound { return results }
                if date.addingTimeInterval(max(duration, 1)) > window.lowerBound { results.append(date) }
            }
            if let count, emitted >= count { return results }
        }
        return results
    }

    private func daysInMonth(_ monthStart: Date, cal: Calendar, defaultDay: Int) -> [Date] {
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let length = range.count
        func day(_ n: Int) -> Date? { cal.date(byAdding: .day, value: n - 1, to: monthStart) }

        if !byMonthDay.isEmpty {
            return byMonthDay.compactMap { n in
                let d = n > 0 ? n : length + n + 1
                return (1...length).contains(d) ? day(d) : nil
            }
        }
        if !byDay.isEmpty {
            return byDay.flatMap { rule -> [Date] in
                let matching = (1...length).compactMap(day).filter { cal.component(.weekday, from: $0) == rule.weekday }
                guard let ordinal = rule.ordinal else { return matching }
                let index = ordinal > 0 ? ordinal - 1 : matching.count + ordinal
                return matching.indices.contains(index) ? [matching[index]] : []
            }
        }
        return defaultDay <= length ? [day(defaultDay)].compactMap { $0 } : []
    }
}

/// Minimal, forgiving RFC 5545 parser for VEVENTs.
public enum ICSParser {
    public static func parse(_ text: String, defaultTimeZone: TimeZone = .current) -> [ICSEvent] {
        var events: [ICSEvent] = []
        var current: [(name: String, params: [String: String], value: String)]?
        var depth = 0 // skip nested components such as VALARM

        for line in unfold(text) {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { current = []; depth = 0; continue }
            guard current != nil else { continue }
            if upper.hasPrefix("BEGIN:") { depth += 1; continue }
            if upper.hasPrefix("END:") && depth > 0 { depth -= 1; continue }
            if upper == "END:VEVENT" {
                if let props = current, let event = makeEvent(props, defaultTimeZone: defaultTimeZone) { events.append(event) }
                current = nil
                continue
            }
            if depth == 0, let prop = parseLine(line) { current?.append(prop) }
        }
        return events
    }

    /// Expand recurring events and apply overrides/exclusions into Meetings within the window.
    public static func meetings(from events: [ICSEvent], calendar: CalendarInfo, window: Range<Date>) -> [Meeting] {
        let overrides = Dictionary(grouping: events.filter { $0.recurrenceID != nil }, by: \.uid)
        var result: [Meeting] = []

        for event in events where event.recurrenceID == nil {
            let duration = event.end.timeIntervalSince(event.start)
            let starts: [Date]
            if let rule = event.rrule {
                let excluded = Set(event.exdates)
                let overridden = Set((overrides[event.uid] ?? []).compactMap(\.recurrenceID))
                starts = rule.occurrences(start: event.start, duration: duration, timeZone: event.timeZone, window: window)
                    .filter { !excluded.contains($0) && !overridden.contains($0) }
            } else {
                starts = (event.start < window.upperBound && event.end > window.lowerBound) ? [event.start] : []
            }
            for start in starts {
                result.append(meeting(event, start: start, end: start.addingTimeInterval(duration), calendar: calendar))
            }
        }
        for event in events where event.recurrenceID != nil && event.start < window.upperBound && event.end > window.lowerBound {
            result.append(meeting(event, start: event.start, end: event.end, calendar: calendar))
        }
        return result
    }

    private static func meeting(_ e: ICSEvent, start: Date, end: Date, calendar: CalendarInfo) -> Meeting {
        Meeting(
            id: "ics:\(calendar.id):\(e.uid)@\(Int(start.timeIntervalSince1970))",
            title: e.summary.isEmpty ? "Untitled" : e.summary,
            start: start,
            end: end,
            isAllDay: e.isAllDay,
            isCanceled: e.status?.uppercased() == "CANCELLED",
            calendar: calendar,
            location: e.location,
            notes: e.description,
            url: e.url,
            organizer: e.organizer,
            organizerEmail: e.organizerEmail,
            attendeeCount: e.attendeeCount,
            attendees: e.attendees,
            participation: .unknown,
            availability: e.transparent ? .free : (e.status?.uppercased() == "TENTATIVE" ? .tentative : .busy),
            joinLink: MeetingLinkDetector.detect(url: e.url, location: e.location, notes: e.description),
            eventColor: e.color,
            recurs: e.rrule != nil || e.recurrenceID != nil
        )
    }

    // MARK: Lines

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    static func parseLine(_ line: String) -> (name: String, params: [String: String], value: String)? {
        // Find the first ':' that is not inside a quoted parameter value.
        var inQuotes = false
        var colon: String.Index?
        for i in line.indices {
            if line[i] == "\"" { inQuotes.toggle() }
            if line[i] == ":" && !inQuotes { colon = i; break }
        }
        guard let colon else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        var segments: [String] = []
        var buffer = ""
        inQuotes = false
        for ch in head {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == ";" && !inQuotes { segments.append(buffer); buffer = ""; continue }
            buffer.append(ch)
        }
        segments.append(buffer)
        let name = segments.removeFirst().uppercased()
        var params: [String: String] = [:]
        for seg in segments {
            let kv = seg.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = String(kv[1]) }
        }
        return (name, params, value)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "n", "N": out.append("\n")
            default: out.append(n)
            }
        }
        return out
    }

    // MARK: Dates

    /// Parses DATE (all-day) or DATE-TIME values, honouring a trailing Z (UTC).
    public static func parseDate(_ value: String, tz: TimeZone) -> (date: Date, allDay: Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if v.count == 8 {
            f.timeZone = .current // all-day dates float in the viewer's zone
            f.dateFormat = "yyyyMMdd"
            return f.date(from: v).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            f.timeZone = tz
            f.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        return f.date(from: v).map { ($0, false) }
    }

    /// IANA ids pass through; common Windows (Outlook/Exchange) names are mapped.
    public static func timeZone(for id: String?) -> TimeZone? {
        guard var id, !id.isEmpty else { return nil }
        id = id.trimmingCharacters(in: CharacterSet(charactersIn: "\"/ "))
        if let tz = TimeZone(identifier: id) { return tz }
        return windowsZones[id].flatMap(TimeZone.init(identifier:))
    }

    static let windowsZones: [String: String] = [
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
        "GTB Standard Time": "Europe/Bucharest", "Russian Standard Time": "Europe/Moscow",
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "Canada Central Standard Time": "America/Regina", "E. South America Standard Time": "America/Sao_Paulo",
        "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo", "Singapore Standard Time": "Asia/Singapore",
        "Korea Standard Time": "Asia/Seoul", "Arabian Standard Time": "Asia/Dubai",
        "Israel Standard Time": "Asia/Jerusalem", "South Africa Standard Time": "Africa/Johannesburg",
        "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
        "W. Australia Standard Time": "Australia/Perth", "New Zealand Standard Time": "Pacific/Auckland",
        "UTC": "UTC", "Coordinated Universal Time": "UTC",
    ]

    // MARK: Event assembly

    private static func makeEvent(_ props: [(name: String, params: [String: String], value: String)], defaultTimeZone: TimeZone) -> ICSEvent? {
        func prop(_ name: String) -> (params: [String: String], value: String)? {
            props.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        func text(_ name: String) -> String? {
            prop(name).map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func date(_ name: String) -> (date: Date, allDay: Bool, tz: TimeZone)? {
            guard let p = prop(name) else { return nil }
            let tz = timeZone(for: p.params["TZID"]) ?? defaultTimeZone
            return parseDate(p.value, tz: tz).map { ($0.date, $0.allDay, tz) }
        }

        guard let start = date("DTSTART") else { return nil }
        var end = date("DTEND")?.date
        if end == nil, let dur = prop("DURATION")?.value, let seconds = parseDuration(dur) {
            end = start.date.addingTimeInterval(seconds)
        }
        let resolvedEnd = end ?? start.date.addingTimeInterval(start.allDay ? 86_400 : 0)

        var exdates: [Date] = []
        for p in props where p.name == "EXDATE" {
            let tz = timeZone(for: p.params["TZID"]) ?? start.tz
            exdates += p.value.split(separator: ",").compactMap { parseDate(String($0), tz: tz)?.date }
        }

        let organizerProp = prop("ORGANIZER")
        let organizerEmail = organizerProp.flatMap { p -> String? in
            let v = p.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            return v.contains("@") ? v : nil
        }
        let organizer = organizerProp.map { p in p.params["CN"] ?? organizerEmail ?? p.value }

        return ICSEvent(
            uid: text("UID") ?? UUID().uuidString,
            summary: text("SUMMARY") ?? "",
            start: start.date,
            end: resolvedEnd,
            isAllDay: start.allDay,
            timeZone: start.tz,
            location: text("LOCATION"),
            description: text("DESCRIPTION") ?? text("X-ALT-DESC"),
            url: text("URL").flatMap(URL.init(string:)),
            status: text("STATUS"),
            transparent: text("TRANSP")?.uppercased() == "TRANSPARENT",
            organizer: organizer,
            organizerEmail: organizerEmail,
            attendeeCount: props.filter { $0.name == "ATTENDEE" }.count,
            attendees: props.filter { $0.name == "ATTENDEE" }.map { p in
                let email = p.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                let cutype = p.params["CUTYPE"]?.uppercased()
                return Attendee(name: p.params["CN"], email: email.contains("@") ? email : nil,
                                isResource: cutype == "ROOM" || cutype == "RESOURCE")
            },
            rrule: prop("RRULE").flatMap { RecurrenceRule($0.value, timeZone: start.tz) },
            exdates: exdates,
            recurrenceID: date("RECURRENCE-ID")?.date,
            color: text("COLOR").flatMap { RGBAColor(css: $0) }
        )
    }

    /// ISO 8601 durations such as PT1H30M, P1D, -PT15M.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        var sign: Double = 1
        var str = Substring(s.uppercased())
        if str.first == "-" { sign = -1; str = str.dropFirst() } else if str.first == "+" { str = str.dropFirst() }
        guard str.first == "P" else { return nil }
        str = str.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for c in str {
            if c == "T" { inTime = true; continue }
            if c.isNumber { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            number = ""
            switch (c, inTime) {
            case ("W", _): total += n * 604_800
            case ("D", _): total += n * 86_400
            case ("H", true): total += n * 3600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: return nil
            }
        }
        return sign * total
    }
}
