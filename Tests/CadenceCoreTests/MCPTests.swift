import Foundation
import Testing
@testable import CadenceCore

private final class FakeBackend: MCPBackend, @unchecked Sendable {
    var calls: [(String, [String: JSONValue], String)] = []
    func callTool(_ name: String, arguments: [String: JSONValue], client: String) async throws -> JSONValue {
        calls.append((name, arguments, client))
        if name == "respond_to_invite" { throw MCPToolError("The user declined this in Cadence.") }
        return ["meetings": [["title": "Standup"]]]
    }
    func readResource(_ uri: String) async throws -> JSONValue { ["uri": .string(uri)] }
}

private func j(_ v: JSONValue) -> JSONValue { v }

private func send(_ s: MCPSession, _ json: JSONValue) async -> JSONValue? {
    await s.handle(json.jsonString).first.flatMap(JSONValue.parse)
}

@Suite("MCP")
struct MCPTests {
    @Test func jsonRoundTrip() {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": ["d": 2.5]]
        #expect(JSONValue.parse(v.jsonString) == v)
        #expect(v.jsonString == #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#)
    }

    @Test func initializeNegotiatesVersionAndRecordsClient() async {
        let s = MCPSession(backend: FakeBackend(), version: "1.0")
        let r = await send(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                               "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code", "version": "2"]]])
        #expect(r?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(r?["result"]?["capabilities"]?["resources"]?["subscribe"]?.boolValue == true)
        #expect(await s.clientName == "claude-code")
        let unknown = await send(s, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(unknown?["result"]?["protocolVersion"]?.stringValue == MCPSession.supportedVersions[0])
        #expect(await s.handle(j(["jsonrpc": "2.0", "method": "notifications/initialized"]).jsonString).isEmpty)
    }

    @Test func toolsListAndCall() async {
        let backend = FakeBackend()
        let s = MCPSession(backend: backend, version: "1.0")
        let list = await send(s, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("get_agenda") && names.contains("respond_to_invite"))
        let respond = list?["result"]?["tools"]?.arrayValue?.first { $0["name"]?.stringValue == "respond_to_invite" }
        #expect(respond?["annotations"]?["readOnlyHint"]?.boolValue == false)

        let ok = await send(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "get_agenda", "arguments": ["date": "2026-11-17"]]])
        #expect(ok?["result"]?["structuredContent"]?["meetings"]?.arrayValue?.count == 1)
        #expect(backend.calls.first?.1["date"]?.stringValue == "2026-11-17")

        let denied = await send(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "respond_to_invite", "arguments": [:]]])
        #expect(denied?["result"]?["isError"]?.boolValue == true)

        let bad = await send(s, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]])
        #expect(bad?["error"]?["code"]?.intValue == JSONRPC.invalidParams)
        let missing = await send(s, ["jsonrpc": "2.0", "id": 5, "method": "bogus/method"])
        #expect(missing?["error"]?["code"]?.intValue == JSONRPC.methodNotFound)
    }

    @Test func subscriptionsAndLogNotifications() async {
        let s = MCPSession(backend: FakeBackend(), version: "1.0")
        _ = await s.handle(j(["jsonrpc": "2.0", "id": 1, "method": "resources/subscribe", "params": ["uri": "cadence://next"]]).jsonString)
        let event = MCPEvent(type: "meeting.started", message: "Standup has started", uris: ["cadence://next", "cadence://invites"])
        let out = await s.deliver(event).compactMap(JSONValue.parse)
        #expect(out.map { $0["method"]?.stringValue } == ["notifications/message", "notifications/resources/updated"])
        #expect(out[1]["params"]?["uri"]?.stringValue == "cadence://next")
        _ = await s.handle(j(["jsonrpc": "2.0", "id": 2, "method": "logging/setLevel", "params": ["level": "warning"]]).jsonString)
        #expect(await s.deliver(MCPEvent(type: "x", message: "quiet")).isEmpty)
    }

    @Test func waitForEventReturnsBufferedThenWaits() async {
        let s = MCPSession(backend: FakeBackend(), version: "1.0")
        _ = await s.deliver(MCPEvent(type: "invite.new", message: "New invite"))
        let r = await send(s, ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": ["name": "wait_for_event", "arguments": ["types": ["invite."], "timeout_seconds": 1]]])
        #expect(r?["result"]?["structuredContent"]?["events"]?.arrayValue?.count == 1)

        async let waiting = send(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                     "params": ["name": "wait_for_event", "arguments": ["timeout_seconds": 5]]])
        try? await Task.sleep(for: .milliseconds(100))
        _ = await s.deliver(MCPEvent(type: "clash.new", message: "Clash"))
        let woken = await waiting
        #expect(woken?["result"]?["structuredContent"]?["events"]?.arrayValue?.first?["type"]?.stringValue == "clash.new")
    }

    @Test func promptsAndResources() async {
        let s = MCPSession(backend: FakeBackend(), version: "1.0")
        let prompt = await send(s, ["jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": ["name": "daily_briefing"]])
        #expect(prompt?["result"]?["messages"]?.arrayValue?.count == 1)
        let read = await send(s, ["jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": ["uri": "cadence://status"]])
        #expect(read?["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue?.contains("cadence://status") == true)
    }
}

@Suite("MCP events and free time")
struct MCPEventTests {
    private let base = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    private func m(_ id: String, _ from: Double, _ to: Double, recurs: Bool = false, free: Bool = false) -> Meeting {
        Meeting(id: id, title: id, start: base.addingTimeInterval(from * 60), end: base.addingTimeInterval(to * 60),
                calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray),
                availability: free ? .free : .busy, recurs: recurs)
    }

    @Test func timelineEvents() {
        let meeting = m("a", 10, 40)
        let soon = MCPEventPlanner.due([meeting], now: base.addingTimeInterval(5 * 60 + 5), sent: [], leadMinutes: 5, wrapMinutes: 5)
        #expect(soon.map(\.type) == ["meeting.starting_soon"])
        let ending = MCPEventPlanner.due([meeting], now: base.addingTimeInterval(35 * 60 + 1), sent: [], leadMinutes: 5, wrapMinutes: 5)
        #expect(ending.map(\.type) == ["meeting.ending_soon"])
        #expect(MCPEventPlanner.due([meeting], now: base.addingTimeInterval(35 * 60 + 1), sent: ["meeting.ending_soon:a"],
                                    leadMinutes: 5, wrapMinutes: 5).isEmpty)
    }

    @Test func detectsMovedAndCanceled() {
        var moved = m("x@1", 60, 90); moved.id = "x@2"; moved.start = base.addingTimeInterval(120 * 60); moved.end = base.addingTimeInterval(150 * 60)
        var canceled = m("y@1", 60, 90); canceled.isCanceled = true
        let changes = MeetingChangeDetector.changes(old: [m("x@1", 60, 90), m("y@1", 60, 90), m("r@1", 0, 30, recurs: true)],
                                                    new: [moved, canceled, m("r@2", 30, 60, recurs: true)], now: base)
        #expect(changes.count == 2)
        #expect(changes.contains(.canceled(canceled)))
    }

    @Test func freeSlots() {
        let day = Calendar.current.startOfDay(for: base)
        // Pick a weekday.
        var d = day
        while Calendar.current.isDateInWeekend(d) { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
        func at(_ h: Double) -> Date { d.addingTimeInterval(h * 3600) }
        let busy = [
            Meeting(id: "a", title: "a", start: at(10), end: at(11), calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray)),
            Meeting(id: "b", title: "b", start: at(11.25), end: at(12), calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray)),
            Meeting(id: "f", title: "f", start: at(13), end: at(14), calendar: CalendarInfo(id: "c", title: "c", sourceTitle: "s", color: .gray), availability: .free),
        ]
        let slots = FreeTimeFinder.slots(meetings: busy, from: d, to: d.addingTimeInterval(86_400), minDuration: 30 * 60,
                                         workStart: 9 * 60, workEnd: 17 * 60)
        #expect(slots.map { $0.start } == [at(9), at(12)])
        #expect(slots.last?.end == at(17))
        #expect(FreeTimeFinder.parseHours("09:00-17:30")! == (540, 1050))
        #expect(FreeTimeFinder.parseHours("18-9") == nil)
    }

    @Test func meetingDTO() {
        let dto = MeetingDTO(m("a", 10, 40), now: base)
        #expect(dto.status == "upcoming")
        #expect(dto.minutes_until_start == 10)
        #expect(dto.start.hasPrefix(String(MeetingDTO.format(base).prefix(10))))
    }
}
