import Foundation

/// A tool Cadence offers to MCP clients.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// Changes something, so the user must approve it in Cadence (unless auto-approved).
    public var isAction: Bool
    /// Changes Cadence's own data without asking (enrichments): not read-only, but no approval card.
    public var writes: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, isAction: Bool, writes: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.isAction = isAction
        self.writes = writes
    }

    public var definition: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": .bool(!isAction && !writes), "destructiveHint": false, "openWorldHint": .bool(isAction)],
        ]
    }
}

public enum MCPCatalog {
    static func schema(_ props: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
    }

    static let meetingID: JSONValue = ["type": "string", "description": "A meeting id from get_agenda, get_next_meeting or list_invites."]
    static let date: JSONValue = ["type": "string", "description": "ISO 8601 date (2026-11-18) or date-time."]

    public static let tools: [MCPTool] = baseTools + EnrichmentTools.tools

    static let baseTools: [MCPTool] = [
        MCPTool(name: "get_agenda", title: "Get agenda",
                description: "Meetings across all of the user's calendars (merged, filtered and de-duplicated, as shown in Cadence). Defaults to today. Cadence fetches roughly today and tomorrow; further ahead, use list_invites.",
                inputSchema: schema([
                    "date": date, "from": date, "to": date,
                    "include_declined": ["type": "boolean", "description": "Include invitations the user declined. Default false."],
                ]), isAction: false),
        MCPTool(name: "get_next_meeting", title: "Next meeting",
                description: "The next timed meeting that hasn't started, with time until it starts, join link and location.",
                inputSchema: schema(), isAction: false),
        MCPTool(name: "get_current_meeting", title: "Current meeting",
                description: "Meetings in progress right now, with time remaining.", inputSchema: schema(), isAction: false),
        MCPTool(name: "list_invites", title: "Invites awaiting reply",
                description: "Invitations the user hasn't answered, one per recurring series.",
                inputSchema: schema(["horizon": ["type": "string", "enum": ["today", "twoDays", "week", "all"],
                                                 "description": "How far ahead to look. Defaults to the user's setting."]]),
                isAction: false),
        MCPTool(name: "list_clashes", title: "Clashes",
                description: "Groups of overlapping meetings (real double-bookings, not copies), and which one the user chose to be alerted for.",
                inputSchema: schema(), isAction: false),
        MCPTool(name: "find_free_time", title: "Find free time",
                description: "Free slots of at least the given length within working hours, based on the meetings Cadence knows about (busy, accepted or tentative).",
                inputSchema: schema([
                    "duration_minutes": ["type": "integer", "minimum": 5, "description": "Minimum slot length."],
                    "from": date, "to": date,
                    "working_hours": ["type": "string", "description": "e.g. \"09:00-17:30\". Defaults to the user's setting."],
                ], required: ["duration_minutes"]), isAction: false),
        MCPTool(name: "list_calendars", title: "Calendars",
                description: "Every calendar Cadence sees, its source (Google, Microsoft, iCloud, ICS…) and whether it's enabled.",
                inputSchema: schema(), isAction: false),
        MCPTool(name: "get_status", title: "Status",
                description: "Whether the user is presenting or on a call right now, and what the next alert is.",
                inputSchema: schema(), isAction: false),
        MCPTool(name: "wait_for_event", title: "Wait for an event",
                description: "Blocks until Cadence has a calendar event (meeting starting/started/ending/ended, new invite, meeting moved or cancelled, new clash, presenting or call status change) or the timeout passes. Returns events that happened since the previous call too.",
                inputSchema: schema([
                    "types": ["type": "array", "items": ["type": "string"],
                              "description": "Only these event types (prefix match, e.g. \"meeting.\"). Default: all."],
                    "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300, "description": "Default 60."],
                ]), isAction: false),
        MCPTool(name: "respond_to_invite", title: "Reply to an invite",
                description: "Accept, tentatively accept or decline an invitation; the organiser is notified. The user confirms in Cadence first.",
                inputSchema: schema(["meeting_id": meetingID,
                                     "reply": ["type": "string", "enum": ["accept", "tentative", "decline"]]],
                                    required: ["meeting_id", "reply"]), isAction: true),
        MCPTool(name: "set_event_color", title: "Set event colour",
                description: "Colour an event, or null for the calendar colour. Use the calendar's own colour label names (the user may have named colours in Google Calendar) or Google's palette names: Tomato, Flamingo, Tangerine, Banana, Sage, Basil, Peacock, Blueberry, Lavender, Grape, Graphite. The user confirms in Cadence first.",
                inputSchema: schema(["meeting_id": meetingID,
                                     "color": ["type": ["string", "null"], "description": "Colour name, or null."]],
                                    required: ["meeting_id"]), isAction: true),
        MCPTool(name: "join_meeting", title: "Join a meeting",
                description: "Opens the meeting's video link (Zoom, Meet, Teams…) on the user's Mac. The user confirms in Cadence first.",
                inputSchema: schema(["meeting_id": meetingID], required: ["meeting_id"]), isAction: true),
        MCPTool(name: "hide_from_panel", title: "Hide from countdown panel",
                description: "Stop showing a meeting (or every occurrence of a recurring one) in Cadence's floating countdown. The user confirms in Cadence first.",
                inputSchema: schema(["meeting_id": meetingID,
                                     "all_occurrences": ["type": "boolean", "description": "Default false."]],
                                    required: ["meeting_id"]), isAction: true),
        MCPTool(name: "snooze_alert", title: "Snooze alert",
                description: "Delay Cadence's full-screen alert for a meeting. The user confirms in Cadence first.",
                inputSchema: schema(["meeting_id": meetingID,
                                     "minutes": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Default 1."]],
                                    required: ["meeting_id"]), isAction: true),
    ]

    public static func tool(_ name: String) -> MCPTool? { tools.first { $0.name == name } }

    public static let resources: [(uri: String, name: String, description: String)] = [
        ("cadence://agenda/today", "Today's agenda", "All of today's meetings."),
        ("cadence://agenda/tomorrow", "Tomorrow's agenda", "All of tomorrow's meetings."),
        ("cadence://next", "Next meeting", "The next meeting, or the one in progress."),
        ("cadence://invites", "Invites awaiting reply", "Unanswered invitations within the user's horizon."),
        ("cadence://clashes", "Clashes", "Overlapping meetings."),
        ("cadence://status", "Status", "Presenting / on-call state and the next alert."),
    ]

    public static let prompts: [(name: String, description: String, arguments: [(String, String, Bool)])] = [
        ("daily_briefing", "A short briefing on today's meetings, clashes and invites.", []),
        ("prepare_for_meeting", "Help the user prepare for a meeting.", [("meeting_id", "Meeting id (defaults to the next meeting)", false)]),
        ("triage_invites", "Go through unanswered invites and suggest replies.", []),
        ("enrich_meeting", "Attach prep notes, links, an agenda and a bingo card to a meeting.", [("meeting_id", "Meeting id (defaults to the next meeting)", false)]),
    ]

    public static func promptText(_ name: String, arguments: [String: String]) -> String? {
        switch name {
        case "daily_briefing":
            return "Using the Cadence tools, give me a concise briefing for today: call get_agenda, list_clashes and list_invites. Mention the first meeting, back-to-back stretches, clashes and invites that need a reply, and the largest free block (find_free_time with 30 minutes). Keep it short."
        case "prepare_for_meeting":
            let which = arguments["meeting_id"].map { "the meeting with id \($0) (look it up with get_agenda)" } ?? "my next meeting (get_next_meeting)"
            return "Help me prepare for \(which): who's attending, the organiser, where or how to join, how long until it starts, what's straight before and after it, and anything in the notes worth knowing. Suggest a 3-point prep checklist."
        case "triage_invites":
            return "Call list_invites and get_agenda. For each invite, check for clashes with what I've already accepted and suggest Accept, Maybe or Decline with a one-line reason. Don't reply to anything until I confirm; then use respond_to_invite."
        case "enrich_meeting":
            let which = arguments["meeting_id"].map { "the meeting with id \($0)" } ?? "my next meeting (get_next_meeting)"
            return "Get ready for \(which) and attach what will help me during it with add_enrichment: a markdown summary of what it's about and what I should know (from its notes and any linked documents you can read), a links list of the documents, a short timed agenda if one is implied, briefs for attendees I may not know, and a fun buzzword bingo card fitting the meeting. Check get_enrichments first and update rather than duplicate."
        default:
            return nil
        }
    }
}

/// A meeting as returned to MCP clients.
public struct MeetingDTO: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String
    public var all_day: Bool
    public var status: String
    public var minutes_until_start: Int?
    public var minutes_remaining: Int?
    public var calendar: String
    public var calendar_source: String
    public var source_type: String
    public var location: String?
    public var join_url: String?
    public var join_service: String?
    public var organizer: String?
    public var attendee_count: Int
    public var my_response: String
    public var availability: String
    public var recurring: Bool
    public var canceled: Bool
    public var in_clash: Bool
    public var muted_by_clash: Bool
    public var hidden_from_panel: Bool
    /// On an "agenda only" calendar: shown, but never alerts, clashes or counts as current/next.
    public var agenda_only: Bool
    public var notes: String?
    /// Things assistants attached (notes, links, checklists…); see get_enrichments. Nil when none.
    public var enrichment_count: Int?

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public static func format(_ d: Date) -> String { iso.string(from: d) }

    public init(_ m: Meeting, now: Date, inClash: Bool = false, mutedByClash: Bool = false,
                hiddenFromPanel: Bool = false, agendaOnly: Bool = false, includeNotes: Bool = false, enrichmentCount: Int = 0) {
        id = m.id
        title = m.title
        start = Self.format(m.start)
        end = Self.format(m.end)
        all_day = m.isAllDay
        status = m.end <= now ? "past" : (m.start <= now ? "live" : "upcoming")
        minutes_until_start = m.start > now ? Int((m.start.timeIntervalSince(now) / 60).rounded(.up)) : nil
        minutes_remaining = m.isInProgress(at: now) ? Int((m.end.timeIntervalSince(now) / 60).rounded(.up)) : nil
        calendar = m.calendar.title
        calendar_source = m.calendar.sourceTitle
        source_type = m.calendar.kind.rawValue
        location = m.location
        join_url = m.joinLink?.url.absoluteString
        join_service = m.joinLink?.service.displayName
        organizer = m.organizer
        attendee_count = m.attendeeCount
        my_response = m.participation.rawValue
        availability = m.availability.rawValue
        recurring = m.recurs
        canceled = m.isCanceled
        in_clash = inClash
        muted_by_clash = mutedByClash
        hidden_from_panel = hiddenFromPanel
        agenda_only = agendaOnly
        enrichment_count = enrichmentCount > 0 ? enrichmentCount : nil
        if includeNotes, let n = m.notes {
            let text = MeetingLinkDetector.plainText(n)
            notes = text.count > 2000 ? String(text.prefix(2000)) + "…" : (text.isEmpty ? nil : text)
        }
    }
}
