import Foundation
import Testing
@testable import CadenceCore

private let cal = CalendarInfo(id: "c", title: "Work", sourceTitle: "Google", color: .gray)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func meeting(_ id: String = "ev1@1800000000", recurs: Bool = false, start: Date = t0) -> Meeting {
    Meeting(id: id, title: "Standup", start: start, end: start.addingTimeInterval(1800), calendar: cal, recurs: recurs)
}

private func add(_ book: inout EnrichmentBook, _ m: Meeting, kind: String, content: JSONValue, extra: [String: JSONValue] = [:]) throws -> JSONValue {
    var args: [String: JSONValue] = ["meeting_id": .string(m.id), "kind": .string(kind), "content": content]
    args.merge(extra) { $1 }
    return try EnrichmentTools.call("add_enrichment", args, book: &book, meeting: { id in
        guard id == m.id else { throw MCPToolError("No meeting") }
        return m
    }, client: "Claude", now: t0).result
}

private func bingoSquares(_ n: Int) -> JSONValue { ["squares": .array((1...n).map { .string("word \($0)") })] }

@Suite("Enrichments")
struct EnrichmentTests {
    @Test func parsesEveryKindLeniently() throws {
        let md = try EnrichmentParser.parse(kind: "markdown", "# Hi", seed: "")
        #expect(md == .markdown("# Hi"))
        let check = try EnrichmentParser.parse(kind: "checklist", ["Read the doc", ["text": "Bring numbers"]], seed: "")
        guard case .checklist(let items) = check else { Issue.record("not a checklist"); return }
        #expect(items.map(\.text) == ["Read the doc", "Bring numbers"])
        let stats = try EnrichmentParser.parse(kind: "stats", ["items": [["label": "ARR", "value": 4.2, "trend": "UP"]]], seed: "")
        #expect(stats == .stats([StatTile(id: StableHash.hex("arr"), label: "ARR", value: "4.2", trend: .up)]))
        let log = try EnrichmentParser.parse(kind: "log", ["items": [["type": "decision", "text": "Ship it"]]], seed: "")
        guard case .log(let entries) = log else { Issue.record("not a log"); return }
        #expect(entries.first?.type == .decision && entries.first?.by == .assistant)
        #expect(throws: MCPToolError.self) { try EnrichmentParser.parse(kind: "poll", ["x": 1], seed: "") }
        #expect(throws: MCPToolError.self) { try EnrichmentParser.parse(kind: "checklist", ["items": []], seed: "") }
    }

    @Test func linksOnlyAllowWebAndMail() throws {
        let ok = try EnrichmentParser.parse(kind: "links", ["items": [["title": "Doc", "url": "https://docs.example.com/x"], "mailto:a@b.co"]], seed: "")
        guard case .links(let links) = ok else { Issue.record("not links"); return }
        #expect(links.count == 2 && links[0].host == "docs.example.com" && links[1].host == "Email")
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "zoommtg://x", "not a url"] {
            #expect(throws: MCPToolError.self) { try EnrichmentParser.parse(kind: "links", [["url": .string(bad)]], seed: "") }
        }
    }

    @Test func bingoFitsCardAndSamplesStably() throws {
        // 30 squares for a 5×5 with free centre: 24 picked, the same each time for the same meeting.
        let a = try EnrichmentParser.parse(kind: "bingo", bingoSquares(30), seed: "m1")
        let b = try EnrichmentParser.parse(kind: "bingo", bingoSquares(30), seed: "m1")
        guard case .bingo(let card) = a else { Issue.record("not bingo"); return }
        #expect(a == b && card.size == 5 && card.squares.count == 24 && card.cells.count == 25 && card.cells[12] == nil)
        // Too few for 5×5 → shrinks to 4×4 (no centre on even cards), then 3×3.
        guard case .bingo(let four) = try EnrichmentParser.parse(kind: "bingo", bingoSquares(16), seed: "") else { return }
        #expect(four.size == 4 && four.cellCount == 16)
        guard case .bingo(let three) = try EnrichmentParser.parse(kind: "bingo", bingoSquares(9), seed: "") else { return }
        #expect(three.size == 3 && three.squares.count == 8)
        #expect(throws: MCPToolError.self) { try EnrichmentParser.parse(kind: "bingo", bingoSquares(5), seed: "") }
        // Stored form decodes to the same card.
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(EnrichmentContent.self, from: data) == a)
    }

    @Test func bingoLines() {
        let squares = (0..<8).map { BingoSquare(id: "s\($0)", text: "\($0)") }
        let card = BingoCard(size: 3, freeCentre: true, squares: squares)
        // Cells: s0 s1 s2 / s3 FREE s4 / s5 s6 s7
        #expect(!card.hasBingo(marked: ["s0", "s1"]))
        #expect(card.lines(marked: ["s0", "s1", "s2"]) == [[0, 1, 2]])
        #expect(card.hasBingo(marked: ["s1", "s6"]))  // middle column through the free centre
        #expect(card.lines(marked: ["s0", "s7"]) == [[0, 4, 8]])
    }

    @Test func unknownKindSurvivesRoundTrip() throws {
        let json = #"{"kind":"poll","value":{"question":"Lunch?"}}"#
        let c = try JSONDecoder().decode(EnrichmentContent.self, from: Data(json.utf8))
        #expect(c == .unsupported(kind: "poll", value: ["question": "Lunch?"]))
        let again = try JSONDecoder().decode(EnrichmentContent.self, from: JSONEncoder().encode(c))
        #expect(again == c)
    }

    @Test func ticksSurviveRewriteByText() throws {
        var book = EnrichmentBook()
        let m = meeting()
        let r = try add(&book, m, kind: "checklist", content: ["Agenda", "Numbers", "Demo"], extra: ["id": "prep"])
        #expect(r["enrichment"]?["id"]?.stringValue == "prep")
        guard case .checklist(let items) = book.enrichment(id: "prep")?.content else { Issue.record("missing"); return }
        book.apply(.toggle(enrichmentID: "prep", itemID: items[0].id), meetingID: m.id)
        book.apply(.toggle(enrichmentID: "prep", itemID: items[2].id), meetingID: m.id)
        // Rewrite: "Demo" removed, "Agenda" kept → its tick stays, the other goes.
        _ = try EnrichmentTools.call("update_enrichment", ["enrichment_id": "prep", "content": ["Agenda", "Risks"]], book: &book,
                                     meeting: { _ in m }, client: "Claude")
        #expect(book.state("prep", meetingID: m.id).checked == [items[0].id])
        #expect(book.items.count == 1)
    }

    @Test func seriesEnrichmentsKeepStatePerOccurrence() throws {
        var book = EnrichmentBook()
        let monday = meeting("ev1@1800000000", recurs: true)
        let tuesday = meeting("ev1@1800086400", recurs: true, start: t0.addingTimeInterval(86_400))
        _ = try add(&book, monday, kind: "bingo", content: bingoSquares(8), extra: ["all_occurrences": true, "id": "b"])
        #expect(book.enrichments(for: tuesday).map(\.id) == ["b"])
        guard case .bingo(let card) = book.enrichment(id: "b")?.content else { return }
        book.apply(.toggle(enrichmentID: "b", itemID: card.squares[0].id), meetingID: monday.id)
        #expect(book.state("b", meetingID: tuesday.id).checked.isEmpty)
        #expect(book.slice(for: [tuesday]).items.count == 1)
        #expect(book.slice(for: [tuesday]).states.isEmpty)
        // One-off meetings ignore all_occurrences.
        var other = EnrichmentBook()
        _ = try add(&other, meeting(), kind: "markdown", content: ["text": "x"], extra: ["all_occurrences": true])
        #expect(other.items.first?.seriesID == nil)
    }

    @Test func getReturnsUserState() throws {
        var book = EnrichmentBook()
        let m = meeting()
        _ = try add(&book, m, kind: "bingo", content: bingoSquares(8), extra: ["id": "b"])
        _ = try add(&book, m, kind: "log", content: ["items": [["type": "action", "text": "Send deck", "owner": "Pat"]]], extra: ["id": "l"])
        guard case .bingo(let card) = book.enrichment(id: "b")?.content else { return }
        let before = book.state("b", meetingID: m.id)
        book.apply(.toggle(enrichmentID: "b", itemID: card.squares[0].id), meetingID: m.id)
        book.apply(.toggle(enrichmentID: "b", itemID: card.squares[1].id), meetingID: m.id)
        let after = book.apply(.toggle(enrichmentID: "b", itemID: card.squares[2].id), meetingID: m.id)!
        book.apply(.addEntry(enrichmentID: "l", entry: LogEntry(type: .decision, text: "  Go with plan B ")), meetingID: m.id)
        #expect(book.apply(.addEntry(enrichmentID: "l", entry: LogEntry(type: .note, text: "   ")), meetingID: m.id) == nil)
        #expect(book.apply(.toggle(enrichmentID: "b", itemID: "nope"), meetingID: m.id) == nil)

        let got = try EnrichmentTools.call("get_enrichments", ["meeting_id": .string(m.id)], book: &book, meeting: { _ in m }, client: "x", now: t0)
        let list = got.result["enrichments"]?.arrayValue ?? []
        #expect(list.count == 2 && !got.changed)
        #expect(list[0]["state"]?["has_bingo"]?.boolValue == true)
        #expect(list[0]["state"]?["marked"]?.arrayValue?.count == 3)
        #expect(list[1]["content"]?["items"]?.arrayValue?.first?["owner"]?.stringValue == "Pat")
        #expect(list[1]["state"]?["user_entries"]?.arrayValue?.first?["text"]?.stringValue == "Go with plan B")

        let e = book.enrichment(id: "b")!
        let event = EnrichmentTools.event(for: .toggle(enrichmentID: "b", itemID: card.squares[2].id), enrichment: e,
                                          before: before, after: after, meeting: m)
        #expect(event.type == "enrichment.bingo")
    }

    @Test func removeClearAndLimits() throws {
        var book = EnrichmentBook()
        let m = meeting()
        for i in 0..<EnrichmentBook.maxPerMeeting { _ = try add(&book, m, kind: "markdown", content: ["text": .string("n\(i)")]) }
        #expect(throws: MCPToolError.self) { try add(&book, m, kind: "markdown", content: ["text": "one too many"]) }
        let first = book.items[0].id
        _ = try EnrichmentTools.call("remove_enrichment", ["enrichment_id": .string(first)], book: &book, meeting: { _ in m }, client: "x")
        #expect(book.enrichment(id: first) == nil)
        #expect(throws: MCPToolError.self) {
            try EnrichmentTools.call("remove_enrichment", ["enrichment_id": .string(first)], book: &book, meeting: { _ in m }, client: "x")
        }
        let cleared = try EnrichmentTools.call("clear_enrichments", ["meeting_id": .string(m.id)], book: &book, meeting: { _ in m }, client: "x")
        #expect(cleared.result["removed_count"]?.intValue == EnrichmentBook.maxPerMeeting - 1 && book.isEmpty)
        #expect(throws: MCPToolError.self) {
            try EnrichmentTools.call("add_enrichment", ["meeting_id": "other", "kind": "markdown", "content": ["text": "x"]], book: &book,
                                     meeting: { _ in throw MCPToolError("No meeting") }, client: "x")
        }
    }

    @Test func pruneDropsOldOneOffs() throws {
        var book = EnrichmentBook()
        _ = try add(&book, meeting(), kind: "markdown", content: ["text": "x"])
        book.prune(now: t0.addingTimeInterval(10 * 86_400))
        #expect(book.items.count == 1)
        book.prune(now: t0.addingTimeInterval(15 * 86_400))
        #expect(book.isEmpty)
    }

    @Test func agendaTimeline() {
        let items = [AgendaItem(id: "a", title: "Intro", minutes: 5), AgendaItem(id: "b", title: "Demo", minutes: 10),
                     AgendaItem(id: "c", title: "Q&A", minutes: 15)]
        let at7 = AgendaTimeline.slots(items, start: t0, done: [], now: t0.addingTimeInterval(7 * 60))
        #expect(at7.map(\.status) == [.current, .upcoming, .upcoming])
        #expect(at7[0].overrun == 120 && at7[0].progress == 1)
        let next = AgendaTimeline.slots(items, start: t0, done: ["a"], now: t0.addingTimeInterval(10 * 60))
        #expect(next.map(\.status) == [.done, .current, .upcoming])
        #expect(abs(next[1].progress - 0.5) < 0.001 && next[1].overrun == 0)
        #expect(AgendaTimeline.totalMinutes(items) == 30)
    }

    @Test func toolsAreWritesWithoutApproval() {
        let add = MCPCatalog.tool("add_enrichment")
        #expect(add?.isAction == false && add?.writes == true)
        #expect(add?.definition["annotations"]?["readOnlyHint"]?.boolValue == false)
        #expect(MCPCatalog.tool("get_enrichments")?.definition["annotations"]?["readOnlyHint"]?.boolValue == true)
        #expect(EnrichmentTools.names.allSatisfy { MCPCatalog.tool($0) != nil })
    }

    @Test func companionCarriesEnrichments() throws {
        var book = EnrichmentBook()
        _ = try add(&book, meeting(), kind: "checklist", content: ["One", "Two"])
        let snap = CompanionSnapshot(macName: "Mac", generatedAt: t0, meetings: [meeting()], enrichments: book)
        let frame = try CompanionFraming.encode(.snapshot(snap))
        var decoder = CompanionFrameDecoder()
        #expect(try decoder.append(frame) == [.snapshot(snap)])
        // A snapshot from an older Mac has no enrichments.
        let old = #"{"macName":"Mac","generatedAt":0,"meetings":[],"suppressedIDs":[],"takeoverEnabled":true,"takeoverLeadSeconds":30}"#
        #expect(try JSONDecoder().decode(CompanionSnapshot.self, from: Data(old.utf8)).enrichments == nil)
        let action = CompanionMessage.enrichmentAction(meetingID: "m", action: .addEntry(enrichmentID: "e", entry: LogEntry(id: "x", type: .action, text: "Do it")))
        #expect(try decoder.append(CompanionFraming.encode(action)) == [action])
    }
}

@Suite("Markdown blocks")
struct MarkdownBlocksTests {
    @Test func parsesBlocks() {
        let md = """
        # Title
        Some **bold** text
        that wraps.

        - one
          - nested
        - [x] done task
        1. first
        2) second

        > quoted
        ---
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownBlocks.parse(md)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nthat wraps."),
            .list([
                MarkdownListItem(text: "one"),
                MarkdownListItem(text: "nested", depth: 1),
                MarkdownListItem(text: "done task", task: true),
                MarkdownListItem(text: "first", ordinal: 1),
                MarkdownListItem(text: "second", ordinal: 2),
            ]),
            .quote("quoted"),
            .rule,
            .code(language: "swift", text: "let x = 1"),
        ])
    }

    @Test func edgeCases() {
        #expect(MarkdownBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlocks.parse("#### Deep ##") == [.heading(level: 3, text: "Deep")])
        #expect(MarkdownBlocks.parse("```\nunclosed") == [.code(language: nil, text: "unclosed")])
        #expect(MarkdownBlocks.parse("2026. A year") == [.paragraph("2026. A year")])
        #expect(MarkdownBlocks.parse("").isEmpty)
    }
}
