import Foundation

// MARK: - Model

/// Something an assistant attached to a meeting: notes, links, a checklist, a bingo card…
/// The assistant writes the content; what the user does with it (ticks, marks, log entries) lives in
/// `EnrichmentState`, so rewriting the content keeps their ticks.
public struct Enrichment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The occurrence it belongs to (for a series enrichment, the occurrence it was added from).
    public var meetingID: String
    /// Set when it applies to every occurrence of a recurring meeting.
    public var seriesID: String?
    public var title: String
    public var content: EnrichmentContent
    /// The assistant that wrote it.
    public var source: String
    public var order: Int
    public var created: Date
    public var updated: Date
    /// When the occurrence ends, for pruning.
    public var meetingEnd: Date?

    public init(id: String, meetingID: String, seriesID: String? = nil, title: String, content: EnrichmentContent,
                source: String = "", order: Int = 0, created: Date = Date(), updated: Date = Date(), meetingEnd: Date? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.seriesID = seriesID
        self.title = title
        self.content = content
        self.source = source
        self.order = order
        self.created = created
        self.updated = updated
        self.meetingEnd = meetingEnd
    }

    public var kind: String { content.kind }

    public func applies(to meeting: Meeting) -> Bool {
        if let seriesID { return seriesID == meeting.seriesID }
        return meetingID == meeting.id
    }
}

public enum EnrichmentKind: String, CaseIterable, Sendable {
    case markdown, links, checklist, bingo, agenda, people, log, stats

    public var label: String {
        switch self {
        case .markdown: return "Notes"
        case .links: return "Links"
        case .checklist: return "Checklist"
        case .bingo: return "Bingo"
        case .agenda: return "Agenda"
        case .people: return "People"
        case .log: return "Decisions & actions"
        case .stats: return "Numbers"
        }
    }

    public var symbol: String {
        switch self {
        case .markdown: return "doc.text"
        case .links: return "link"
        case .checklist: return "checklist"
        case .bingo: return "square.grid.3x3.fill"
        case .agenda: return "list.bullet.clipboard"
        case .people: return "person.2"
        case .log: return "checkmark.seal"
        case .stats: return "chart.bar"
        }
    }
}

public struct EnrichmentLink: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: URL
    public var note: String?
    public init(id: String, title: String, url: URL, note: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.note = note
    }
    public var host: String { url.scheme == "mailto" ? "Email" : (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") }
}

public struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct BingoSquare: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// A size×size card. `squares` fill it row by row, skipping the centre when `freeCentre`.
public struct BingoCard: Codable, Equatable, Sendable {
    public static let freeID = "free"
    public var size: Int
    public var freeCentre: Bool
    public var squares: [BingoSquare]

    public init(size: Int, freeCentre: Bool, squares: [BingoSquare]) {
        self.size = size; self.freeCentre = freeCentre; self.squares = squares
    }

    public var hasCentre: Bool { freeCentre && size % 2 == 1 }
    public var cellCount: Int { size * size - (hasCentre ? 1 : 0) }

    /// Every cell, row by row; nil is the free centre.
    public var cells: [BingoSquare?] {
        var out: [BingoSquare?] = []
        var it = squares.makeIterator()
        for i in 0..<(size * size) {
            if hasCentre && i == (size * size) / 2 { out.append(nil) } else { out.append(it.next()) }
        }
        return out
    }

    /// Completed rows, columns and diagonals, as cell indexes.
    public func lines(marked: Set<String>) -> [[Int]] {
        let cells = cells
        func on(_ i: Int) -> Bool { cells[i].map { marked.contains($0.id) } ?? true }
        var candidates: [[Int]] = []
        for r in 0..<size { candidates.append((0..<size).map { r * size + $0 }) }
        for c in 0..<size { candidates.append((0..<size).map { $0 * size + c }) }
        candidates.append((0..<size).map { $0 * size + $0 })
        candidates.append((0..<size).map { $0 * size + (size - 1 - $0) })
        return candidates.filter { $0.allSatisfy(on) }
    }

    public func hasBingo(marked: Set<String>) -> Bool { !lines(marked: marked).isEmpty }
}

public struct AgendaItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var minutes: Int
    public var owner: String?
    public init(id: String, title: String, minutes: Int, owner: String? = nil) {
        self.id = id; self.title = title; self.minutes = minutes; self.owner = owner
    }
}

public struct PersonBrief: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var email: String?
    public var role: String?
    /// Markdown.
    public var notes: String?
    public init(id: String, name: String, email: String? = nil, role: String? = nil, notes: String? = nil) {
        self.id = id; self.name = name; self.email = email; self.role = role; self.notes = notes
    }
}

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public enum EntryType: String, Codable, CaseIterable, Sendable {
        case decision, action, note
        public var label: String { rawValue.capitalized }
    }
    public enum Author: String, Codable, Sendable { case assistant, user }
    public var id: String
    public var type: EntryType
    public var text: String
    public var owner: String?
    public var due: String?
    public var by: Author
    public var at: Date?

    public init(id: String = UUID().uuidString, type: EntryType, text: String, owner: String? = nil, due: String? = nil,
                by: Author = .user, at: Date? = nil) {
        self.id = id; self.type = type; self.text = text; self.owner = owner; self.due = due; self.by = by; self.at = at
    }
}

public struct StatTile: Codable, Equatable, Identifiable, Sendable {
    public enum Trend: String, Codable, Sendable { case up, down, flat }
    public var id: String
    public var label: String
    public var value: String
    public var delta: String?
    public var trend: Trend?
    /// Whether "up" is good (green) — false for things like costs or bugs.
    public var upIsGood: Bool
    public init(id: String, label: String, value: String, delta: String? = nil, trend: Trend? = nil, upIsGood: Bool = true) {
        self.id = id; self.label = label; self.value = value; self.delta = delta; self.trend = trend; self.upIsGood = upIsGood
    }
}

/// The content of one enrichment. Stored and sent as `{"kind": …, "value": <assistant-shaped JSON>}`,
/// so a kind this build doesn't know survives as `.unsupported` and is passed along untouched.
public enum EnrichmentContent: Equatable, Sendable, Codable {
    case markdown(String)
    case links([EnrichmentLink])
    case checklist([ChecklistItem])
    case bingo(BingoCard)
    case agenda([AgendaItem])
    case people([PersonBrief])
    case log([LogEntry])
    case stats([StatTile])
    case unsupported(kind: String, value: JSONValue)

    public var kind: String {
        switch self {
        case .markdown: return "markdown"
        case .links: return "links"
        case .checklist: return "checklist"
        case .bingo: return "bingo"
        case .agenda: return "agenda"
        case .people: return "people"
        case .log: return "log"
        case .stats: return "stats"
        case .unsupported(let kind, _): return kind
        }
    }

    public var knownKind: EnrichmentKind? { EnrichmentKind(rawValue: kind) }

    /// Ids the user can tick (checklist items, bingo squares, agenda items).
    public var tickableIDs: Set<String> {
        switch self {
        case .checklist(let items): return Set(items.map(\.id))
        case .bingo(let card): return Set(card.squares.map(\.id))
        case .agenda(let items): return Set(items.map(\.id))
        default: return []
        }
    }

    private enum Keys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let value = try c.decode(JSONValue.self, forKey: .value)
        if EnrichmentKind(rawValue: kind) != nil, let parsed = try? EnrichmentParser.parse(kind: kind, value, seed: "") {
            self = parsed
        } else {
            self = .unsupported(kind: kind, value: value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(json, forKey: .value)
    }

    /// The assistant-facing shape (what add_enrichment takes and get_enrichments returns).
    public var json: JSONValue {
        func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        func items(_ list: [JSONValue]) -> JSONValue { ["items": .array(list)] }
        switch self {
        case .markdown(let text): return ["text": .string(text)]
        case .links(let links):
            return items(links.map { ["id": .string($0.id), "title": .string($0.title), "url": .string($0.url.absoluteString), "note": opt($0.note)] })
        case .checklist(let list):
            return items(list.map { ["id": .string($0.id), "text": .string($0.text)] })
        case .bingo(let card):
            return ["size": .number(Double(card.size)), "free_centre": .bool(card.freeCentre),
                    "squares": .array(card.squares.map { ["id": .string($0.id), "text": .string($0.text)] })]
        case .agenda(let list):
            return items(list.map { ["id": .string($0.id), "title": .string($0.title), "minutes": .number(Double($0.minutes)), "owner": opt($0.owner)] })
        case .people(let list):
            return items(list.map { ["id": .string($0.id), "name": .string($0.name), "email": opt($0.email), "role": opt($0.role), "notes": opt($0.notes)] })
        case .log(let list):
            return items(list.map(EnrichmentParser.logJSON))
        case .stats(let list):
            return items(list.map { ["id": .string($0.id), "label": .string($0.label), "value": .string($0.value), "delta": opt($0.delta),
                                     "trend": opt($0.trend?.rawValue), "up_is_good": .bool($0.upIsGood)] })
        case .unsupported(_, let value): return value
        }
    }
}

// MARK: - User state

/// What the user did with an enrichment in one meeting occurrence.
public struct EnrichmentState: Codable, Equatable, Sendable {
    public var enrichmentID: String
    public var meetingID: String
    public var checked: Set<String>
    /// Entries the user added (decisions, actions, notes).
    public var entries: [LogEntry]
    public var updated: Date

    public init(enrichmentID: String, meetingID: String, checked: Set<String> = [], entries: [LogEntry] = [], updated: Date = Date()) {
        self.enrichmentID = enrichmentID; self.meetingID = meetingID; self.checked = checked; self.entries = entries; self.updated = updated
    }
}

/// Something the user does to an enrichment (on the Mac, or sent from the phone).
public enum EnrichmentAction: Codable, Equatable, Sendable {
    case toggle(enrichmentID: String, itemID: String)
    case addEntry(enrichmentID: String, entry: LogEntry)
    case removeEntry(enrichmentID: String, entryID: String)

    public var enrichmentID: String {
        switch self {
        case .toggle(let id, _), .addEntry(let id, _), .removeEntry(let id, _): return id
        }
    }
}

// MARK: - Book

/// Every enrichment and the user's state for them. Pure value type; the Mac persists it.
public struct EnrichmentBook: Codable, Equatable, Sendable {
    public static let maxPerMeeting = 20
    public var items: [Enrichment]
    public var states: [EnrichmentState]

    public init(items: [Enrichment] = [], states: [EnrichmentState] = []) {
        self.items = items
        self.states = states
    }

    public var isEmpty: Bool { items.isEmpty }

    public func enrichments(for meeting: Meeting) -> [Enrichment] {
        items.filter { $0.applies(to: meeting) }.sorted { ($0.order, $0.created) < ($1.order, $1.created) }
    }

    public func enrichment(id: String) -> Enrichment? { items.first { $0.id == id } }

    public func state(_ enrichmentID: String, meetingID: String) -> EnrichmentState {
        states.first { $0.enrichmentID == enrichmentID && $0.meetingID == meetingID }
            ?? EnrichmentState(enrichmentID: enrichmentID, meetingID: meetingID, updated: .distantPast)
    }

    /// Adds or replaces an enrichment. Returns the stored one.
    @discardableResult
    public mutating func upsert(_ e: Enrichment, now: Date = Date()) -> Enrichment {
        var e = e
        if let i = items.firstIndex(where: { $0.id == e.id }) {
            e.created = items[i].created
            e.order = items[i].order
            e.updated = now
            items[i] = e
        } else {
            e.created = now
            e.updated = now
            items.append(e)
        }
        // Ticks on items that no longer exist go.
        let valid = e.content.tickableIDs
        for i in states.indices where states[i].enrichmentID == e.id {
            states[i].checked.formIntersection(valid)
        }
        return e
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        states.removeAll { $0.enrichmentID == id }
        return items.count != before
    }

    /// Removes everything on this occurrence (and, with `series`, its series ones). Returns how many.
    @discardableResult
    public mutating func clear(meeting: Meeting, series: Bool) -> Int {
        let gone = items.filter { $0.seriesID == nil ? $0.meetingID == meeting.id : (series && $0.seriesID == meeting.seriesID) }.map(\.id)
        gone.forEach { remove(id: $0) }
        return gone.count
    }

    /// Applies a user action. Returns the new state, or nil if the enrichment or item doesn't exist.
    @discardableResult
    public mutating func apply(_ action: EnrichmentAction, meetingID: String, now: Date = Date()) -> EnrichmentState? {
        guard let e = enrichment(id: action.enrichmentID) else { return nil }
        var s = state(e.id, meetingID: meetingID)
        switch action {
        case .toggle(_, let item):
            guard e.content.tickableIDs.contains(item) else { return nil }
            if s.checked.contains(item) { s.checked.remove(item) } else { s.checked.insert(item) }
        case .addEntry(_, var entry):
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, s.entries.count < 200 else { return nil }
            entry.text = String(text.prefix(1000))
            entry.by = .user
            entry.at = entry.at ?? now
            s.entries.append(entry)
        case .removeEntry(_, let entryID):
            s.entries.removeAll { $0.id == entryID }
        }
        s.updated = now
        if let i = states.firstIndex(where: { $0.enrichmentID == e.id && $0.meetingID == meetingID }) { states[i] = s } else { states.append(s) }
        return s
    }

    /// Drops one-off enrichments two weeks after their meeting, series ones untouched for 90 days,
    /// and state older than 30 days.
    public mutating func prune(now: Date = Date()) {
        let gone = items.filter { e in
            if e.seriesID != nil { return now.timeIntervalSince(e.updated) > 90 * 86_400 }
            return now.timeIntervalSince(e.meetingEnd ?? e.updated) > 14 * 86_400
        }.map(\.id)
        gone.forEach { remove(id: $0) }
        let ids = Set(items.map(\.id))
        states.removeAll { !ids.contains($0.enrichmentID) || now.timeIntervalSince($0.updated) > 30 * 86_400 }
    }

    /// Only what applies to these meetings, with their states (what the phone gets).
    public func slice(for meetings: [Meeting]) -> EnrichmentBook {
        let ids = Set(meetings.map(\.id))
        let series = Set(meetings.filter(\.recurs).map(\.seriesID))
        let kept = items.filter { $0.seriesID.map(series.contains) ?? ids.contains($0.meetingID) }
        let keptIDs = Set(kept.map(\.id))
        return EnrichmentBook(items: kept, states: states.filter { keptIDs.contains($0.enrichmentID) && ids.contains($0.meetingID) })
    }
}

// MARK: - Agenda timing

/// Where a timed agenda is, given when the meeting started.
public enum AgendaTimeline {
    public enum Status: Equatable, Sendable { case done, current, upcoming }

    public struct Slot: Equatable, Sendable {
        public var item: AgendaItem
        public var start: Date
        public var end: Date
        public var status: Status
        /// 0...1 through the slot's planned time (only for the current one).
        public var progress: Double
        /// Seconds past the slot's planned end (current only).
        public var overrun: TimeInterval
    }

    /// The current item is the first one not ticked; times are planned back-to-back from the start.
    public static func slots(_ items: [AgendaItem], start: Date, done: Set<String>, now: Date) -> [Slot] {
        var t = start
        var foundCurrent = false
        return items.map { item in
            let end = t.addingTimeInterval(Double(max(0, item.minutes)) * 60)
            defer { t = end }
            let status: Status
            if done.contains(item.id) { status = .done } else if !foundCurrent { status = .current; foundCurrent = true } else { status = .upcoming }
            var progress = 0.0, overrun = 0.0
            if status == .current {
                let length = end.timeIntervalSince(t)
                progress = length > 0 ? min(1, max(0, now.timeIntervalSince(t) / length)) : 1
                overrun = max(0, now.timeIntervalSince(end))
            }
            return Slot(item: item, start: t, end: end, status: status, progress: progress, overrun: overrun)
        }
    }

    public static func totalMinutes(_ items: [AgendaItem]) -> Int { items.reduce(0) { $0 + max(0, $1.minutes) } }
}

// MARK: - Parsing assistant input

/// Turns what an assistant sends into content, leniently (strings for simple items, `items` or a bare
/// array), and checks limits. Throws `MCPToolError` with a message the model can act on.
public enum EnrichmentParser {
    public static let maxItems = 100
    public static let maxMarkdown = 20_000
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func parse(kind: String, _ value: JSONValue, seed: String) throws -> EnrichmentContent {
        guard let k = EnrichmentKind(rawValue: kind) else {
            throw MCPToolError("Unknown kind \"\(kind)\". Use one of: " + EnrichmentKind.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        switch k {
        case .markdown:
            guard let text = (value.stringValue ?? value["text"]?.stringValue ?? value["markdown"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw MCPToolError("markdown content needs {\"text\": \"…\"}.")
            }
            guard text.count <= maxMarkdown else { throw MCPToolError("markdown is limited to \(maxMarkdown) characters.") }
            return .markdown(text)
        case .links:
            var ids = IDs()
            return .links(try list(value, "links").map { v in
                guard let raw = (v["url"]?.stringValue ?? v.stringValue)?.trimmingCharacters(in: .whitespaces),
                      let url = URL(string: raw), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
                    throw MCPToolError("Each link needs a url starting with http://, https:// or mailto:.")
                }
                let title = text(v["title"]) ?? url.host ?? raw
                return EnrichmentLink(id: ids.next(v["id"], url.absoluteString), title: title, url: url, note: text(v["note"]))
            })
        case .checklist:
            var ids = IDs()
            return .checklist(try list(value, "checklist").map { v in
                guard let t = text(v) ?? text(v["text"]) ?? text(v["title"]) else { throw MCPToolError("Each checklist item needs text.") }
                return ChecklistItem(id: ids.next(v["id"], t), text: t)
            })
        case .bingo:
            return .bingo(try bingo(value, seed: seed))
        case .agenda:
            var ids = IDs()
            return .agenda(try list(value, "agenda").map { v in
                guard let t = text(v["title"]) ?? text(v) ?? text(v["text"]) else { throw MCPToolError("Each agenda item needs a title.") }
                let minutes = min(600, max(0, v["minutes"]?.intValue ?? 5))
                return AgendaItem(id: ids.next(v["id"], t), title: t, minutes: minutes, owner: text(v["owner"]))
            })
        case .people:
            var ids = IDs()
            return .people(try list(value, "people").map { v in
                guard let name = text(v["name"]) ?? text(v) else { throw MCPToolError("Each person needs a name.") }
                return PersonBrief(id: ids.next(v["id"], name), name: name, email: text(v["email"])?.lowercased(),
                                   role: text(v["role"]), notes: text(v["notes"]).map { String($0.prefix(4000)) })
            })
        case .log:
            var ids = IDs()
            return .log(try list(value, "log").map { v in
                guard let t = text(v["text"]) ?? text(v) else { throw MCPToolError("Each log entry needs text.") }
                let type = v["type"]?.stringValue.flatMap { LogEntry.EntryType(rawValue: $0.lowercased()) } ?? .note
                return LogEntry(id: ids.next(v["id"], t), type: type, text: t, owner: text(v["owner"]), due: text(v["due"]), by: .assistant)
            })
        case .stats:
            var ids = IDs()
            return .stats(try list(value, "stats").map { v in
                guard let label = text(v["label"]) else { throw MCPToolError("Each stat needs a label and value.") }
                let value: String
                if let s = text(v["value"]) { value = s } else if let n = v["value"]?.doubleValue { value = n.rounded() == n ? String(Int(n)) : String(n) } else {
                    throw MCPToolError("Each stat needs a label and value.")
                }
                return StatTile(id: ids.next(v["id"], label), label: label, value: value, delta: text(v["delta"]),
                                trend: v["trend"]?.stringValue.flatMap { StatTile.Trend(rawValue: $0.lowercased()) },
                                upIsGood: v["up_is_good"]?.boolValue ?? true)
            })
        }
    }

    static func logJSON(_ e: LogEntry) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(e.id), "type": .string(e.type.rawValue), "text": .string(e.text), "by": .string(e.by.rawValue)]
        if let owner = e.owner { o["owner"] = .string(owner) }
        if let due = e.due { o["due"] = .string(due) }
        if let at = e.at { o["at"] = .string(MeetingDTO.format(at)) }
        return .object(o)
    }

    // MARK: Helpers

    private static func text(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(2000))
    }

    private static func list(_ value: JSONValue, _ kind: String) throws -> [JSONValue] {
        guard let items = value.arrayValue ?? value["items"]?.arrayValue ?? value[kind]?.arrayValue else {
            throw MCPToolError("\(kind) content needs {\"items\": [...]}.")
        }
        guard !items.isEmpty else { throw MCPToolError("\(kind) needs at least one item.") }
        guard items.count <= maxItems else { throw MCPToolError("\(kind) is limited to \(maxItems) items.") }
        return items
    }

    /// Ids for items: the given one, else a stable hash of the text (so a rewrite keeps ticks).
    struct IDs {
        var used: Set<String> = []
        mutating func next(_ given: JSONValue?, _ text: String) -> String {
            var id = given?.stringValue?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? given?.intValue.map(String.init) ?? StableHash.hex(text.lowercased())
            id = String(id.prefix(64))
            if id == BingoCard.freeID { id += "-1" }
            var candidate = id, n = 2
            while used.contains(candidate) { candidate = "\(id)-\(n)"; n += 1 }
            used.insert(candidate)
            return candidate
        }
    }

    private static func bingo(_ value: JSONValue, seed: String) throws -> BingoCard {
        let raw = value.arrayValue ?? value["squares"]?.arrayValue ?? value["items"]?.arrayValue ?? []
        guard raw.count <= maxItems else { throw MCPToolError("bingo is limited to \(maxItems) squares.") }
        var ids = IDs()
        var squares: [BingoSquare] = raw.compactMap { v in
            guard let t = text(v) ?? text(v["text"]) else { return nil }
            return BingoSquare(id: ids.next(v["id"], String(t.prefix(80))), text: String(t.prefix(80)))
        }
        let free = value["free_centre"]?.boolValue ?? value["free_center"]?.boolValue ?? true
        func needed(_ n: Int) -> Int { n * n - (free && n % 2 == 1 ? 1 : 0) }
        var size = min(5, max(3, value["size"]?.intValue ?? 5))
        while size > 3 && squares.count < needed(size) { size -= 1 }
        guard squares.count >= needed(size) else {
            throw MCPToolError("A bingo card needs at least \(needed(3)) squares (3×3\(free ? " with a free centre" : "")); got \(squares.count).")
        }
        if squares.count > needed(size) {
            // More than fit: pick a stable random subset for this meeting.
            var rng = SeededGenerator(seed: StableHash.value(seed + squares.map(\.text).joined()))
            squares.shuffle(using: &rng)
            squares = Array(squares.prefix(needed(size)))
        }
        return BingoCard(size: size, freeCentre: free, squares: squares)
    }
}

/// FNV-1a: stable across launches and devices (Swift's `hashValue` isn't).
public enum StableHash {
    public static func value(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return h
    }
    public static func hex(_ s: String) -> String { String(String(value(s), radix: 16).prefix(10)) }
}

/// SplitMix64.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
