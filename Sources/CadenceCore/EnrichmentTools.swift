import Foundation

/// The MCP tools for enrichments. They only change what Cadence shows, so they need no approval card.
public enum EnrichmentTools {
    public static let names: Set<String> = ["add_enrichment", "update_enrichment", "remove_enrichment", "clear_enrichments", "get_enrichments"]

    public struct Outcome: Sendable {
        public var result: JSONValue
        /// The book changed (save it, refresh the drawer, sync the phone).
        public var changed: Bool
    }

    /// Runs one enrichment tool against `book`. `meeting` resolves a meeting id (throwing for unknown ids).
    public static func call(_ name: String, _ a: [String: JSONValue], book: inout EnrichmentBook,
                            meeting: (String) throws -> Meeting, client: String, now: Date = Date()) throws -> Outcome {
        switch name {
        case "add_enrichment":
            let m = try meeting(try required(a, "meeting_id"))
            guard let kind = a["kind"]?.stringValue?.lowercased() else { throw MCPToolError("kind is required.") }
            let title = a["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? EnrichmentKind(rawValue: kind)?.label ?? kind
            let content = try EnrichmentParser.parse(kind: kind, a["content"] ?? .null, seed: m.id)
            let sources = try EnrichmentParser.sources(a["sources"])
            let series = (a["all_occurrences"]?.boolValue ?? false) && m.recurs
            let id = a["id"]?.stringValue?.trimmingCharacters(in: .whitespaces).nilIfEmpty.map { String($0.prefix(64)) }
                ?? "enr_" + UUID().uuidString.prefix(8).lowercased()
            let existing = book.enrichment(id: id)
            if existing == nil, book.enrichments(for: m).count >= EnrichmentBook.maxPerMeeting {
                throw MCPToolError("A meeting can have at most \(EnrichmentBook.maxPerMeeting) enrichments; remove or update one first.")
            }
            let order = existing?.order ?? ((book.enrichments(for: m).map(\.order).max() ?? -1) + 1)
            let stored = book.upsert(Enrichment(id: id, meetingID: m.id, seriesID: series ? m.seriesID : nil,
                                                title: String(title.prefix(80)), content: content,
                                                source: client, order: order, meetingEnd: series ? nil : m.end,
                                                sources: sources), now: now)
            return Outcome(result: ["done": true, "replaced": .bool(existing != nil),
                                    "enrichment": dto(stored, state: book.state(stored.id, meetingID: m.id), meeting: m, now: now)],
                           changed: true)

        case "update_enrichment":
            let id = try required(a, "enrichment_id")
            guard var e = book.enrichment(id: id) else { throw unknown(id) }
            if let t = a["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { e.title = String(t.prefix(80)) }
            if let c = a["content"] {
                e.content = try EnrichmentParser.parse(kind: a["kind"]?.stringValue?.lowercased() ?? e.kind, c, seed: e.meetingID)
            }
            if let src = a["sources"] { e.sources = try EnrichmentParser.sources(src) }
            e.source = client
            let stored = book.upsert(e, now: now)
            return Outcome(result: ["done": true, "enrichment": dto(stored, state: book.state(id, meetingID: e.meetingID), meeting: nil, now: now)],
                           changed: true)

        case "remove_enrichment":
            let id = try required(a, "enrichment_id")
            guard book.remove(id: id) else { throw unknown(id) }
            return Outcome(result: ["done": true, "removed": .string(id)], changed: true)

        case "clear_enrichments":
            let m = try meeting(try required(a, "meeting_id"))
            let n = book.clear(meeting: m, series: a["all_occurrences"]?.boolValue ?? false)
            return Outcome(result: ["done": true, "removed_count": .number(Double(n))], changed: n > 0)

        case "get_enrichments":
            let m = try meeting(try required(a, "meeting_id"))
            let list = book.enrichments(for: m)
            return Outcome(result: ["meeting_id": .string(m.id), "meeting_title": .string(m.title),
                                    "enrichments": .array(list.map { dto($0, state: book.state($0.id, meetingID: m.id), meeting: m, now: now) })],
                           changed: false)

        default:
            throw MCPToolError("Unknown tool \(name).")
        }
    }

    /// An enrichment with what the user did with it, for assistants.
    public static func dto(_ e: Enrichment, state s: EnrichmentState, meeting: Meeting?, now: Date) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(e.id), "kind": .string(e.kind), "title": .string(e.title),
            "all_occurrences": .bool(e.seriesID != nil), "source": .string(e.source),
            "updated": .string(MeetingDTO.format(e.updated)), "content": e.content.json,
        ]
        if !e.sources.isEmpty { out["sources"] = .array(e.sources.map(\.json)) }
        var state: [String: JSONValue] = [:]
        let checked = s.checked.sorted()
        switch e.content {
        case .checklist(let items):
            state["checked"] = .array(checked.map(JSONValue.string))
            state["progress"] = .string("\(items.filter { s.checked.contains($0.id) }.count)/\(items.count)")
        case .bingo(let card):
            state["marked"] = .array(checked.map(JSONValue.string))
            state["marked_text"] = .array(card.squares.filter { s.checked.contains($0.id) }.map { .string($0.text) })
            state["lines"] = .number(Double(card.lines(marked: s.checked).count))
            state["has_bingo"] = .bool(card.hasBingo(marked: s.checked))
        case .agenda(let items):
            state["done"] = .array(checked.map(JSONValue.string))
            if let m = meeting, m.start <= now {
                let slots = AgendaTimeline.slots(items, start: m.start, done: s.checked, now: now)
                if let cur = slots.first(where: { $0.status == .current }) {
                    state["current_item"] = .string(cur.item.id)
                    if cur.overrun > 0 { state["current_overrun_minutes"] = .number((cur.overrun / 60).rounded()) }
                }
            }
        default: break
        }
        if !s.entries.isEmpty { state["user_entries"] = .array(s.entries.map(EnrichmentParser.logJSON)) }
        if !state.isEmpty {
            if s.updated > .distantPast { state["updated"] = .string(MeetingDTO.format(s.updated)) }
            out["state"] = .object(state)
        }
        return .object(out)
    }

    private static func required(_ a: [String: JSONValue], _ key: String) throws -> String {
        guard let v = a[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { throw MCPToolError("\(key) is required.") }
        return v
    }

    private static func unknown(_ id: String) -> MCPToolError {
        MCPToolError("No enrichment with id \(id). Get ids from get_enrichments.")
    }

    /// Which assistant-facing event a user action produces.
    public static func event(for action: EnrichmentAction, enrichment e: Enrichment, before: EnrichmentState, after: EnrichmentState,
                             meeting: Meeting, now: Date = Date()) -> MCPEvent {
        let payload: JSONValue = ["meeting_id": .string(meeting.id), "enrichment": dto(e, state: after, meeting: meeting, now: now)]
        if case .bingo(let card) = e.content, !card.hasBingo(marked: before.checked), card.hasBingo(marked: after.checked) {
            return MCPEvent(type: "enrichment.bingo", message: "BINGO in \(meeting.title)!", data: payload)
        }
        let what: String
        switch action {
        case .toggle(_, let item):
            let on = after.checked.contains(item)
            what = on ? "ticked an item in \(e.title)" : "unticked an item in \(e.title)"
        case .addEntry(_, let entry): what = "logged a \(entry.type.rawValue) in \(e.title)"
        case .removeEntry: what = "removed an entry from \(e.title)"
        }
        return MCPEvent(type: "enrichment.changed", message: "The user \(what) (\(meeting.title))", data: payload)
    }

    // MARK: Catalog

    static let enrichmentID: JSONValue = ["type": "string", "description": "An enrichment id from add_enrichment or get_enrichments."]

    static let sources: JSONValue = [
        "type": "array",
        "description": "Where you got this from, shown to the user as citations. Add one for each document, page, email thread, ticket, calendar note or other place you drew on, with what you took from it. Please include these whenever the content isn't purely your own.",
        "items": [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "What it is, e.g. \"Q3 planning doc\" or \"Email from Sam, 12 Nov\"."],
                "url": ["type": "string", "description": "Link to it (http/https/mailto), if it has one."],
                "description": ["type": "string", "description": "What you got from it, e.g. \"Launch dates and owners\"."],
            ],
            "required": ["name"],
        ],
    ]

    static let contentDescription = """
    Shape depends on kind. markdown: {"text": "# Heading\\n- bullets, **bold**, [links](https://…), - [ ] tasks"}. \
    links: {"items": [{"title" (the link's name, shown instead of its domain), "url" (http/https/mailto), "note"?}]}. \
    checklist: {"items": ["text", …] or [{"id"?, "text"}]} (the user ticks them). \
    bingo: {"squares": ["synergy", "circle back", …], "size"?: 3-5 (default 5), "free_centre"?: true} — \
    needs at least size²−1 squares; extras are sampled per meeting. \
    agenda: {"items": [{"title", "minutes", "owner"?}]} (timed from the meeting start; the user ticks items done). \
    people: {"items": [{"name", "email"?, "role"?, "notes"? (markdown), "photo_url"? (https profile picture, if you have one)}]}. \
    log: {"items": [{"type": "decision"|"action"|"note", "text", "owner"?, "due"?}]} (the user adds entries in the meeting). \
    stats: {"items": [{"label", "value", "delta"?, "trend"?: "up"|"down"|"flat", "up_is_good"?: true}]}. \
    Give items stable "id"s if you'll rewrite them; otherwise ids come from the text, so the user's ticks survive a rewrite.
    """

    static var tools: [MCPTool] {
        [
            MCPTool(name: "add_enrichment", title: "Attach to a meeting",
                    description: "Attach notes, links, a checklist, a bingo card, a timed agenda, attendee briefs, a decisions & actions log or key numbers to a meeting. The user sees them in Cadence during the meeting (Mac drawer, iPhone desk mode) and can tick things off; read that back with get_enrichments. Passing an existing id replaces it. Cite where the content came from in sources. No confirmation needed.",
                    inputSchema: MCPCatalog.schema([
                        "meeting_id": MCPCatalog.meetingID,
                        "kind": ["type": "string", "enum": .array(EnrichmentKind.allCases.map { .string($0.rawValue) })],
                        "title": ["type": "string", "description": "Short tab title, e.g. \"Prep notes\". Defaults to the kind's name."],
                        "content": ["type": "object", "description": .string(contentDescription)],
                        "sources": sources,
                        "all_occurrences": ["type": "boolean", "description": "For recurring meetings: show it in every occurrence (ticks are kept per occurrence). Default false."],
                        "id": ["type": "string", "description": "Optional id to create or replace."],
                    ], required: ["meeting_id", "kind", "content"]), isAction: false, writes: true),
            MCPTool(name: "update_enrichment", title: "Update an attachment",
                    description: "Change an enrichment's title, content (same shape as add_enrichment) or sources. The user's ticks on items that still exist are kept. Passing sources replaces them; leaving it out keeps them.",
                    inputSchema: MCPCatalog.schema([
                        "enrichment_id": enrichmentID,
                        "title": ["type": "string"],
                        "content": ["type": "object", "description": "Same shape as add_enrichment for its kind."],
                        "sources": sources,
                    ], required: ["enrichment_id"]), isAction: false, writes: true),
            MCPTool(name: "remove_enrichment", title: "Remove an attachment",
                    description: "Remove one enrichment (and what the user ticked on it).",
                    inputSchema: MCPCatalog.schema(["enrichment_id": enrichmentID], required: ["enrichment_id"]), isAction: false, writes: true),
            MCPTool(name: "clear_enrichments", title: "Clear a meeting's attachments",
                    description: "Remove every enrichment on a meeting occurrence; with all_occurrences, also the ones shown on every occurrence.",
                    inputSchema: MCPCatalog.schema([
                        "meeting_id": MCPCatalog.meetingID,
                        "all_occurrences": ["type": "boolean", "description": "Default false."],
                    ], required: ["meeting_id"]), isAction: false, writes: true),
            MCPTool(name: "get_enrichments", title: "Read a meeting's attachments",
                    description: "Everything attached to a meeting and what the user did with it: ticked checklist items, bingo squares (has_bingo), agenda progress and decisions/actions they logged. Use after a meeting (wait_for_event \"meeting.ended\") to follow up.",
                    inputSchema: MCPCatalog.schema(["meeting_id": MCPCatalog.meetingID], required: ["meeting_id"]), isAction: false),
        ]
    }
}
