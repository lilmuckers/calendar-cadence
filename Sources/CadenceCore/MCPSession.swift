import Foundation

/// What an MCP session needs from the app.
public protocol MCPBackend: Sendable {
    /// Runs a tool (other than wait_for_event, which the session handles). Throw `MCPToolError` for
    /// failures the model should see (unknown meeting, user declined…).
    func callTool(_ name: String, arguments: [String: JSONValue], client: String) async throws -> JSONValue
    func readResource(_ uri: String) async throws -> JSONValue
    /// Called after every tools/call, for the activity log.
    func record(_ entry: MCPActivityEntry) async
}

extension MCPBackend {
    public func record(_ entry: MCPActivityEntry) async {}
}

public struct MCPToolError: LocalizedError, Sendable {
    public enum Kind: Sendable { case failed, denied, timedOut }
    public var message: String
    public var kind: Kind
    /// Short description for the activity log (defaults to the message).
    public var note: String?
    public init(_ message: String, kind: Kind = .failed, note: String? = nil) {
        self.message = message
        self.kind = kind
        self.note = note
    }
    public var errorDescription: String? { message }
}

/// One client connection speaking MCP (JSON-RPC 2.0, one message per line).
/// Transport-agnostic: feed it lines, write back what it returns.
public actor MCPSession {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let backend: MCPBackend
    private let version: String
    public private(set) var clientName = "An assistant"
    public private(set) var initialized = false
    private var subscriptions: Set<String> = []
    private var logLevel = 1
    /// Events since the last wait_for_event call, for clients that poll.
    private var buffer: [MCPEvent] = []
    private var waiters: [UUID: (types: [String], resume: CheckedContinuation<[MCPEvent], Never>)] = [:]

    public init(backend: MCPBackend, version: String) {
        self.backend = backend
        self.version = version
    }

    static let instructions = """
    Cadence is the user's calendar monitor on this Mac. It merges every calendar they've connected \
    (macOS Calendar, Google, Microsoft 365, ICS feeds), applies their filters and removes duplicates, so \
    its answers match what the user sees. Times are in the user's local time zone. Read tools are free to \
    call. Action tools (respond_to_invite, set_event_color, join_meeting, hide_from_panel, snooze_alert) \
    show the user a confirmation card in Cadence and fail if they decline. Enrichment tools (add_enrichment, \
    update_enrichment, get_enrichments…) attach notes, links, checklists, agendas, attendee briefs, a decisions log, \
    key numbers or a buzzword bingo card to a meeting without asking; the user sees them during the meeting and \
    what they tick or log comes back in get_enrichments and as enrichment.* events. Use wait_for_event to be told \
    about meetings starting or ending, new invites, changes, clashes and presenting/call status.
    """

    // MARK: Incoming

    /// Handles one incoming line and returns the lines to send back (responses only).
    public func handle(_ line: String) async -> [String] {
        guard let message = JSONValue.parse(line), case .object(let msg) = message else {
            return [JSONRPC.error(id: .null, code: JSONRPC.parseError, message: "Parse error").jsonString]
        }
        guard let method = msg["method"]?.stringValue else { return [] }  // responses to us: ignore
        let params = msg["params"]?.objectValue ?? [:]
        guard let id = msg["id"] else {
            if method == "notifications/initialized" { initialized = true }
            return []
        }
        do {
            let result = try await dispatch(method, params)
            return [JSONRPC.response(id: id, result: result).jsonString]
        } catch let error as RPCFailure {
            return [JSONRPC.error(id: id, code: error.code, message: error.message).jsonString]
        } catch {
            return [JSONRPC.error(id: id, code: -32603, message: error.localizedDescription).jsonString]
        }
    }

    private struct RPCFailure: Error { var code: Int; var message: String }

    private func dispatch(_ method: String, _ p: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "initialize":
            if let name = p["clientInfo"]?["title"]?.stringValue ?? p["clientInfo"]?["name"]?.stringValue { clientName = name }
            let requested = p["protocolVersion"]?.stringValue ?? Self.supportedVersions[0]
            let chosen = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return [
                "protocolVersion": .string(chosen),
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": true, "listChanged": false],
                    "prompts": ["listChanged": false],
                    "logging": [:],
                ],
                "serverInfo": ["name": "cadence", "title": "Cadence", "version": .string(version)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(MCPCatalog.tools.map(\.definition))]
        case "tools/call":
            guard let name = p["name"]?.stringValue, MCPCatalog.tool(name) != nil else {
                throw RPCFailure(code: JSONRPC.invalidParams, message: "Unknown tool")
            }
            return await callTool(name, arguments: p["arguments"]?.objectValue ?? [:])
        case "resources/list":
            return ["resources": .array(MCPCatalog.resources.map {
                ["uri": .string($0.uri), "name": .string($0.name), "description": .string($0.description), "mimeType": "application/json"]
            })]
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "resources/read":
            guard let uri = p["uri"]?.stringValue, MCPCatalog.resources.contains(where: { $0.uri == uri }) else {
                throw RPCFailure(code: -32002, message: "Resource not found")
            }
            let value = try await backend.readResource(uri)
            return ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(value.prettyString)]]]
        case "resources/subscribe":
            guard let uri = p["uri"]?.stringValue else { throw RPCFailure(code: JSONRPC.invalidParams, message: "Missing uri") }
            subscriptions.insert(uri)
            return [:]
        case "resources/unsubscribe":
            if let uri = p["uri"]?.stringValue { subscriptions.remove(uri) }
            return [:]
        case "prompts/list":
            return ["prompts": .array(MCPCatalog.prompts.map { prompt in
                [
                    "name": .string(prompt.name), "description": .string(prompt.description),
                    "arguments": .array(prompt.arguments.map {
                        ["name": .string($0.0), "description": .string($0.1), "required": .bool($0.2)]
                    }),
                ]
            })]
        case "prompts/get":
            let args = (p["arguments"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            guard let name = p["name"]?.stringValue, let text = MCPCatalog.promptText(name, arguments: args) else {
                throw RPCFailure(code: JSONRPC.invalidParams, message: "Unknown prompt")
            }
            return ["messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
        case "logging/setLevel":
            logLevel = Self.rank(p["level"]?.stringValue ?? "info")
            return [:]
        default:
            throw RPCFailure(code: JSONRPC.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func callTool(_ name: String, arguments: [String: JSONValue]) async -> JSONValue {
        let started = Date()
        var result: JSONValue?
        var failure: Error?
        defer {
            let entry = MCPActivity.callEntry(tool: name, client: MCPClientNames.display(clientName), arguments: arguments, result: result,
                                              error: failure, started: started, now: Date())
            let backend = backend
            Task { await backend.record(entry) }
        }
        do {
            let value: JSONValue
            if name == "wait_for_event" {
                let types = arguments["types"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let timeout = min(300, max(1, arguments["timeout_seconds"]?.intValue ?? 60))
                let events = await waitForEvents(types: types, timeout: timeout)
                value = ["events": .array(events.map(\.payload)), "timed_out": .bool(events.isEmpty)]
            } else {
                value = try await backend.callTool(name, arguments: arguments, client: clientName)
            }
            result = value
            // structuredContent must be an object.
            let structured: JSONValue = value.objectValue != nil ? value : ["result": value]
            return ["content": [["type": "text", "text": .string(value.prettyString)]], "structuredContent": structured]
        } catch {
            failure = error
            return ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
        }
    }

    // MARK: Events

    /// Records an event and returns the notifications to send to this client.
    public func deliver(_ event: MCPEvent) -> [String] {
        var out: [String] = []
        if event.log {
            buffer.append(event)
            if buffer.count > 100 { buffer.removeFirst(buffer.count - 100) }
            if Self.rank(event.level) >= logLevel {
                out.append(JSONRPC.notification("notifications/message", params: [
                    "level": .string(event.level), "logger": "cadence", "data": event.payload,
                ]).jsonString)
            }
            wakeWaiters()
        }
        for uri in event.uris where subscriptions.contains(uri) {
            out.append(JSONRPC.notification("notifications/resources/updated", params: ["uri": .string(uri)]).jsonString)
        }
        return out
    }

    private func matching(_ types: [String]) -> [MCPEvent] {
        buffer.filter { e in types.isEmpty || types.contains { e.type.hasPrefix($0) } }
    }

    private func waitForEvents(types: [String], timeout: Int) async -> [MCPEvent] {
        let ready = matching(types)
        if !ready.isEmpty {
            buffer.removeAll { ready.contains($0) }
            return ready
        }
        let id = UUID()
        return await withCheckedContinuation { cont in
            waiters[id] = (types, cont)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume.resume(returning: [])
    }

    private func wakeWaiters() {
        for (id, waiter) in waiters {
            let ready = matching(waiter.types)
            guard !ready.isEmpty else { continue }
            buffer.removeAll { ready.contains($0) }
            waiters.removeValue(forKey: id)
            waiter.resume.resume(returning: ready)
        }
    }

    /// Ends pending waits (connection closed).
    public func close() {
        for (_, w) in waiters { w.resume.resume(returning: []) }
        waiters.removeAll()
    }

    static func rank(_ level: String) -> Int {
        ["debug": 0, "info": 1, "notice": 2, "warning": 3, "error": 4, "critical": 5, "alert": 6, "emergency": 7][level] ?? 1
    }
}
