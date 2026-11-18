// cadence-mcp: stdio MCP server for local AI assistants. A thin relay between the client's
// stdin/stdout and Cadence.app's Unix socket; all calendar logic lives in the app.
// stdout carries only MCP messages; diagnostics go to stderr.

import CadenceCore
import Darwin
import Foundation

let socketPath: String = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Cadence/mcp.sock").path
}()

func log(_ s: String) {
    FileHandle.standardError.write(Data("cadence-mcp: \(s)\n".utf8))
}

/// Cadence.app containing this helper (Contents/MacOS/cadence-mcp), if any.
let appBundle: URL? = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}()

final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private let outLock = NSLock()
    private var fd: Int32 = -1
    private var launched = false
    /// What the client set up, replayed when the app restarts.
    private var initializeLine: String?
    private var initializedLine: String?
    private var subscriptions: [String: String] = [:]
    /// Client requests sent to the app and not yet answered.
    private var inFlight: [String: JSONValue] = [:]
    private static let replayPrefix = "cadence-mcp-replay-"

    // MARK: Output

    func writeOut(_ line: String) {
        outLock.lock(); defer { outLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func replyError(_ id: JSONValue, _ message: String) {
        writeOut(JSONRPC.error(id: id, code: -32000, message: message).jsonString)
    }

    // MARK: Socket

    private func openSocket() -> Int32? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !ok { close(s); return nil }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return s
    }

    private func launchApp() {
        guard !launched else { return }
        launched = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = appBundle.map { ["-g", $0.path] } ?? ["-g", "-b", "com.cadence.calendarmonitor"]
        try? p.run()
        p.waitUntilExit()
        log("launched Cadence")
    }

    /// Connects (launching Cadence if `launch`), replaying the client's session. Call with `lock` held.
    private func ensureConnected(launch: Bool) -> Bool {
        if fd >= 0 { return true }
        var s = openSocket()
        if s == nil && launch {
            launchApp()
            let deadline = Date().addingTimeInterval(10)
            while s == nil && Date() < deadline {
                usleep(250_000)
                s = openSocket()
            }
        }
        guard let s else { return false }
        fd = s
        let reader = Thread { [weak self] in self?.readLoop(s) }
        reader.start()
        // Replay setup so a restarted app knows this client.
        if let initializeLine, var msg = JSONValue.parse(initializeLine)?.objectValue {
            msg["id"] = .string(Self.replayPrefix + "init")
            sendRaw(JSONValue.object(msg).jsonString)
            if let initializedLine { sendRaw(initializedLine) }
            for (uri, _) in subscriptions {
                sendRaw(JSONValue.object([
                    "jsonrpc": "2.0", "id": .string(Self.replayPrefix + UUID().uuidString),
                    "method": "resources/subscribe", "params": ["uri": .string(uri)],
                ]).jsonString)
            }
        }
        return true
    }

    @discardableResult
    private func sendRaw(_ line: String) -> Bool {
        guard fd >= 0 else { return false }
        let data = Array((line + "\n").utf8)
        var sent = 0
        while sent < data.count {
            let n = data[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func readLoop(_ s: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[0..<nl], as: UTF8.self)
                buffer.removeSubrange(0...nl)
                fromApp(line)
            }
        }
        disconnected(s)
    }

    private func fromApp(_ line: String) {
        let msg = JSONValue.parse(line)?.objectValue
        if let id = msg?["id"], msg?["method"] == nil {
            if let s = id.stringValue, s.hasPrefix(Self.replayPrefix) { return }  // our replay
            lock.lock(); inFlight[id.jsonString] = nil; lock.unlock()
        }
        writeOut(line)
    }

    private func disconnected(_ s: Int32) {
        lock.lock()
        guard fd == s else { lock.unlock(); return }
        close(s)
        fd = -1
        let lost = inFlight.values
        inFlight.removeAll()
        lock.unlock()
        for id in lost { replyError(id, "Cadence quit before answering. Try again.") }
        log("disconnected from Cadence")
        // Reconnect quietly (without relaunching) so notifications resume after an app restart.
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<600 {
                sleep(2)
                guard let self else { return }
                self.lock.lock()
                let ok = self.ensureConnected(launch: false)
                self.lock.unlock()
                if ok { log("reconnected"); return }
            }
        }
    }

    // MARK: Input

    func fromClient(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let msg = JSONValue.parse(line)?.objectValue
        let method = msg?["method"]?.stringValue
        let id = msg?["id"]

        lock.lock()
        switch method {
        case "initialize": initializeLine = line
        case "notifications/initialized": initializedLine = line
        case "resources/subscribe": if let uri = msg?["params"]?["uri"]?.stringValue { subscriptions[uri] = line }
        case "resources/unsubscribe": if let uri = msg?["params"]?["uri"]?.stringValue { subscriptions[uri] = nil }
        default: break
        }
        let connected = ensureConnected(launch: true)
        var ok = false
        if connected {
            if let id, method != nil { inFlight[id.jsonString] = id }
            ok = sendRaw(line)
            if !ok, let id { inFlight[id.jsonString] = nil }
        }
        lock.unlock()

        if !ok, let id, method != nil {
            replyError(id, connected
                ? "Lost the connection to Cadence. Try again."
                : "Cadence isn't running and couldn't be started. Open Cadence and check Settings → Assistants is enabled.")
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let relay = Relay()
while let line = readLine(strippingNewline: true) {
    relay.fromClient(line)
}
exit(0)
