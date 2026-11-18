import Foundation

public enum MCPCallOutcome: String, Codable, Sendable, CaseIterable {
    case ok
    case error
    case denied
    case timedOut = "timed_out"
    case autoApproved = "auto_approved"
}

/// One thing an assistant did, kept (locally) for Settings → Assistants → Activity.
public struct MCPActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case call, connect, event }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var client: String?
    public var tool: String?
    public var isAction: Bool?
    public var outcome: MCPCallOutcome?
    public var durationMs: Int?
    public var summary: String?
    public var eventType: String?

    public init(id: UUID = UUID(), at: Date, kind: Kind, client: String? = nil, tool: String? = nil, isAction: Bool? = nil,
                outcome: MCPCallOutcome? = nil, durationMs: Int? = nil, summary: String? = nil, eventType: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.client = client
        self.tool = tool
        self.isAction = isAction
        self.outcome = outcome
        self.durationMs = durationMs
        self.summary = summary
        self.eventType = eventType
    }

    /// Long-polling calls; counted, but not shown as activity.
    public var isWait: Bool { tool == "wait_for_event" }
}

public enum MCPActivity {
    public static let waitTool = "wait_for_event"

    /// Builds the record for a finished tools/call. `result` is what the backend returned.
    public static func callEntry(tool: String, client: String, arguments: [String: JSONValue],
                                 result: JSONValue?, error: Error?, started: Date, now: Date) -> MCPActivityEntry {
        let isAction = MCPCatalog.tool(tool)?.isAction ?? false
        let outcome: MCPCallOutcome
        if let e = error as? MCPToolError {
            switch e.kind {
            case .denied: outcome = .denied
            case .timedOut: outcome = .timedOut
            case .failed: outcome = .error
            }
        } else if error != nil {
            outcome = .error
        } else {
            outcome = result?["approved_by"]?.stringValue == "auto" ? .autoApproved : .ok
        }
        return MCPActivityEntry(at: started, kind: .call, client: client, tool: tool, isAction: isAction, outcome: outcome,
                                durationMs: max(0, Int(now.timeIntervalSince(started) * 1000)),
                                summary: summary(tool: tool, arguments: arguments, result: result, error: error))
    }

    /// A one-line description, without notes or raw payloads.
    static func summary(tool: String, arguments a: [String: JSONValue], result: JSONValue?, error: Error?) -> String {
        if let e = error as? MCPToolError { return String((e.note ?? e.message).prefix(140)) }
        if let error { return String(error.localizedDescription.prefix(140)) }
        func count(_ key: String, _ noun: String) -> String {
            let n = result?[key]?.arrayValue?.count ?? 0
            return "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        func title(_ v: JSONValue?) -> String? { v?["title"]?.stringValue }
        switch tool {
        case "get_agenda":
            let span = a["date"]?.stringValue ?? [a["from"]?.stringValue, a["to"]?.stringValue].compactMap { $0 }.joined(separator: " → ")
            return "\(span.isEmpty ? "today" : span) · \(count("meetings", "meeting"))"
        case "get_next_meeting": return title(result?["meeting"]) ?? "No upcoming meeting"
        case "get_current_meeting": return count("meetings", "meeting") + " in progress"
        case "list_invites": return count("invites", "invite")
        case "list_clashes": return count("clashes", "clash")
        case "find_free_time":
            return "\(a["duration_minutes"]?.intValue ?? 0) min · \(count("slots", "slot"))"
        case "list_calendars": return count("calendars", "calendar")
        case "get_status":
            var bits: [String] = []
            if result?["presenting"]?.boolValue == true { bits.append("presenting") }
            if result?["on_call"]?.boolValue == true { bits.append("on a call") }
            let text = bits.isEmpty ? "free" : bits.joined(separator: ", ")
            return text.prefix(1).uppercased() + text.dropFirst()
        case waitTool:
            let n = result?["events"]?.arrayValue?.count ?? 0
            return n == 0 ? "Timed out" : "\(n) event\(n == 1 ? "" : "s")"
        default:
            let action = result?["action"]?.stringValue ?? tool
            return [action, title(result?["meeting"])].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Drops entries older than `maxAge` and keeps at most `maxCount` (newest).
    public static func prune(_ entries: [MCPActivityEntry], now: Date, maxAge: TimeInterval = 30 * 86_400,
                             maxCount: Int = 5_000) -> [MCPActivityEntry] {
        let recent = entries.filter { now.timeIntervalSince($0.at) <= maxAge }
        return recent.count > maxCount ? Array(recent.suffix(maxCount)) : recent
    }

    public struct Stats: Equatable, Sendable {
        public var callsToday = 0
        public var callsWeek = 0
        public var waitsWeek = 0
        public var actionsAllowed = 0
        public var actionsAuto = 0
        public var actionsDenied = 0
        public var errorsWeek = 0
        public var eventsWeek = 0
        public var sessionsWeek = 0
        /// Calls per tool in the last 7 days, most first.
        public var perTool: [(tool: String, count: Int, isAction: Bool)] = []
        public var perClient: [(client: String, count: Int)] = []
        /// Calls per day, oldest first, 7 entries.
        public var perDay: [(day: Date, count: Int)] = []
        public var eventsByType: [(type: String, count: Int)] = []
        public var busiestTool: String? { perTool.first?.tool }

        public static func == (a: Stats, b: Stats) -> Bool {
            a.callsToday == b.callsToday && a.callsWeek == b.callsWeek && a.waitsWeek == b.waitsWeek
                && a.actionsAllowed == b.actionsAllowed && a.actionsAuto == b.actionsAuto && a.actionsDenied == b.actionsDenied
                && a.errorsWeek == b.errorsWeek && a.eventsWeek == b.eventsWeek && a.sessionsWeek == b.sessionsWeek
                && a.perTool.map(\.tool) == b.perTool.map(\.tool) && a.perTool.map(\.count) == b.perTool.map(\.count)
                && a.perClient.map(\.client) == b.perClient.map(\.client) && a.perDay.map(\.count) == b.perDay.map(\.count)
        }
    }

    /// Last-7-days statistics (today counted separately). `client` filters to one assistant.
    public static func stats(_ entries: [MCPActivityEntry], now: Date, client: String? = nil,
                             calendar: Calendar = .current) -> Stats {
        var s = Stats()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        var tools: [String: (Int, Bool)] = [:]
        var clients: [String: Int] = [:]
        var days: [Date: Int] = [:]
        var events: [String: Int] = [:]
        for e in entries where e.at >= weekStart && e.at <= now.addingTimeInterval(60) {
            if let client, e.kind != .event, e.client != client { continue }
            switch e.kind {
            case .connect: s.sessionsWeek += 1
            case .event:
                s.eventsWeek += 1
                events[e.eventType ?? "?", default: 0] += 1
            case .call:
                if e.isWait { s.waitsWeek += 1; continue }
                s.callsWeek += 1
                if e.at >= today { s.callsToday += 1 }
                let tool = e.tool ?? "?"
                tools[tool] = ((tools[tool]?.0 ?? 0) + 1, e.isAction ?? false)
                clients[e.client ?? "?", default: 0] += 1
                days[calendar.startOfDay(for: e.at), default: 0] += 1
                switch e.outcome {
                case .ok where e.isAction == true: s.actionsAllowed += 1
                case .autoApproved: s.actionsAuto += 1
                case .denied, .timedOut: s.actionsDenied += 1
                case .error: s.errorsWeek += 1
                default: break
                }
            }
        }
        s.perTool = tools.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        s.perClient = clients.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        s.perDay = (0..<7).map { i in
            let day = calendar.date(byAdding: .day, value: i, to: weekStart)!
            return (day, days[day] ?? 0)
        }
        s.eventsByType = events.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return s
    }
}
