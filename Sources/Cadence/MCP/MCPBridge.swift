import AppKit
import CadenceCore
import Foundation
import Network
import Observation

/// Serves MCP to local assistants over a Unix socket that only this user can open. The bundled
/// `cadence-mcp` helper connects here and relays the client's stdio.
@MainActor
@Observable
final class MCPBridge {
    struct Client: Identifiable {
        let id: UUID
        var name: String
        let connectedAt: Date
    }

    static var socketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cadence/mcp.sock").path
    }

    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cadence-mcp").path
    }

    /// The running bridge, for Settings.
    static var current: MCPBridge?

    private(set) var clients: [Client] = []
    private(set) var running = false
    private(set) var lastError: String?

    @ObservationIgnored private let state: AppState
    @ObservationIgnored private let backend: CadenceBackend
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: (NWConnection, MCPSession)] = [:]
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var lastStatus: (presenting: Bool, call: String?)?
    @ObservationIgnored private var pendingStatus: (presenting: Bool, call: String?)?

    let activity = MCPActivityStore()

    init(state: AppState, approvals: ApprovalController) {
        self.state = state
        backend = CadenceBackend(state: state, approvals: approvals, activity: activity)
    }

    func sync() {
        if state.prefs.mcpEnabled { start() } else { stop() }
    }

    func start() {
        guard listener == nil else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .unix(path: path)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] s in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch s {
                        case .ready:
                            chmod(path, 0o600)
                            self?.running = true
                            self?.lastError = nil
                        case .failed(let error):
                            self?.lastError = error.localizedDescription
                            self?.running = false
                        default: break
                        }
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
        state.onEvent = { [weak self] event in self?.broadcast(event) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, (conn, session)) in connections {
            conn.cancel()
            Task { await session.close() }
        }
        connections.removeAll()
        clients.removeAll()
        unlink(Self.socketPath)
        running = false
        state.onEvent = nil
        updateStatusPolling()
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let id = UUID()
        let session = MCPSession(backend: backend, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        connections[id] = (conn, session)
        clients.append(Client(id: id, name: "Connecting…", connectedAt: Date()))
        conn.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled:
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.drop(id) } }
            default: break
            }
        }
        conn.start(queue: .main)
        receive(id, conn, session, buffer: Data())
        updateStatusPolling()
    }

    private func receive(_ id: UUID, _ conn: NWConnection, _ session: MCPSession, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    Task { @MainActor in
                        let out = await session.handle(line)
                        self.send(out, on: conn)
                        if line.contains("\"initialize\"") {
                            let name = MCPClientNames.display(await session.clientName)
                            if let i = self.clients.firstIndex(where: { $0.id == id }) {
                                if self.clients[i].name == "Connecting…" {
                                    self.activity.add(MCPActivityEntry(at: Date(), kind: .connect, client: name))
                                }
                                self.clients[i].name = name
                            }
                        }
                    }
                }
                if isComplete || error != nil {
                    self.drop(id)
                } else {
                    self.receive(id, conn, session, buffer: buffer)
                }
            }
        }
    }

    private func send(_ lines: [String], on conn: NWConnection) {
        guard !lines.isEmpty else { return }
        conn.send(content: Data((lines.joined(separator: "\n") + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func drop(_ id: UUID) {
        guard let (conn, session) = connections.removeValue(forKey: id) else { return }
        conn.cancel()
        Task { await session.close() }
        clients.removeAll { $0.id == id }
        updateStatusPolling()
    }

    // MARK: Events

    private func broadcast(_ event: MCPEvent) {
        if event.log && !connections.isEmpty {
            activity.add(MCPActivityEntry(at: event.at, kind: .event, eventType: event.type))
        }
        for (_, (conn, session)) in connections {
            Task { @MainActor in self.send(await session.deliver(event), on: conn) }
        }
    }

    /// Presenting / call detection costs a little, so only poll while an assistant is connected.
    private func updateStatusPolling() {
        if connections.isEmpty {
            statusTimer?.invalidate()
            statusTimer = nil
            lastStatus = nil
            pendingStatus = nil
        } else if statusTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollStatus() }
            }
            RunLoop.main.add(timer, forMode: .common)
            statusTimer = timer
            pollStatus()
        }
    }

    private func pollStatus() {
        let ctx = SystemContext.current()
        let now = (presenting: ctx.isPresenting, call: ctx.microphoneApp)
        guard let last = lastStatus else { lastStatus = now; return }
        // Only report a change seen on two polls in a row (detection can blip, e.g. at launch).
        guard now.presenting != last.presenting || (now.call != nil) != (last.call != nil) else { pendingStatus = nil; return }
        guard let pending = pendingStatus, pending.presenting == now.presenting, (pending.call != nil) == (now.call != nil) else {
            pendingStatus = now
            return
        }
        pendingStatus = nil
        lastStatus = now
        if now.presenting != last.presenting {
            broadcast(MCPEvent(type: "status.presenting", message: now.presenting ? "Started presenting" : "Stopped presenting",
                               data: ["presenting": .bool(now.presenting)], uris: ["cadence://status"]))
        }
        if (now.call != nil) != (last.call != nil) {
            broadcast(MCPEvent(type: "status.on_call",
                               message: now.call.map { "On a call (\($0))" } ?? "Call ended",
                               data: ["on_call": .bool(now.call != nil), "app": now.call.map { .string($0) } ?? .null],
                               uris: ["cadence://status"]))
        }
    }
}
