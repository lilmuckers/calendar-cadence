import AppKit
import CadenceCore
import Foundation
import Observation
import os

/// Setup diagnostics, also written to Application Support/Cadence/assistants.log (last ~200 lines).
enum AssistantLog {
    private static let logger = Logger(subsystem: "com.cadence.calendarmonitor", category: "assistants")
    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cadence/assistants.log")
    }()

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(line.trimmingCharacters(in: .newlines))
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// MCP clients Cadence knows how to set up.
enum AssistantClient: String, CaseIterable, Identifiable {
    case claudeDesktop, claudeCode, cursor, windsurf

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        }
    }

    var bundleID: String? {
        switch self {
        case .claudeDesktop: "com.anthropic.claudefordesktop"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .windsurf: "com.exafunction.windsurf"
        case .claudeCode: nil
        }
    }

    /// JSON file holding `mcpServers`. Claude Code's is read only; changes go through its CLI.
    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .claudeCode: return home.appendingPathComponent(".claude.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .windsurf: return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        }
    }

    /// Whether an MCP `clientInfo` name/title belongs to this client.
    func matches(clientName: String) -> Bool {
        let n = clientName.lowercased().replacingOccurrences(of: " ", with: "-")
        switch self {
        case .claudeDesktop:
            return n == "claude" || n.hasPrefix("claude-ai") || n == "claude-desktop" || n.hasPrefix("local-agent-mode")
                || n == "claude-(code-tab)"
        case .claudeCode: return n.hasPrefix("claude-code")
        case .cursor: return n.contains("cursor")
        case .windsurf: return n.contains("windsurf")
        }
    }

    /// Needs restarting to pick up a new server.
    var restartsToLoad: Bool { self != .claudeCode }

    func manualSetup(helper: String) -> String {
        switch self {
        case .claudeCode:
            return "claude mcp add --scope user cadence -- \"\(helper)\""
        default:
            return MCPClientConfig.installing(into: nil, helperPath: helper).prettyString
        }
    }
}

struct AssistantClientStatus: Equatable {
    var installed = false
    var running = false
    var config: MCPClientConfig.Status = .missing
    var problem: String?
}

/// Detects assistants on this Mac and adds or removes Cadence from them.
@MainActor
@Observable
final class AssistantClients {
    private(set) var status: [AssistantClient: AssistantClientStatus] = [:]
    private(set) var busy: Set<AssistantClient> = []
    var lastError: String?
    private(set) var claudeCLI: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var helperPath: String { MCPBridge.helperPath }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        Task { await self.findClaudeCLI(); self.refresh() }
    }

    func appURL(_ c: AssistantClient) -> URL? {
        c.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    func refresh() {
        var out: [AssistantClient: AssistantClientStatus] = [:]
        for c in AssistantClient.allCases {
            var s = AssistantClientStatus()
            if let id = c.bundleID {
                s.installed = appURL(c) != nil
                s.running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
            } else {
                s.installed = claudeCLI != nil
            }
            do {
                let config = try MCPClientConfig.parse(try? Data(contentsOf: c.configURL))
                s.config = MCPClientConfig.status(config, helperPath: helperPath)
            } catch {
                s.problem = "\(c.configURL.lastPathComponent) isn't valid JSON, so Cadence won't change it."
            }
            out[c] = s
        }
        status = out
    }

    // MARK: Install / remove

    func install(_ c: AssistantClient) async {
        await run(c) {
            if c == .claudeCode {
                _ = try? await self.claude(["mcp", "remove", "--scope", "user", "cadence"])
                try await self.claude(["mcp", "add", "--scope", "user", "cadence", "--", self.helperPath])
            } else {
                try self.editConfig(c) { MCPClientConfig.installing(into: $0, helperPath: self.helperPath) }
            }
        }
    }

    func remove(_ c: AssistantClient) async {
        await run(c) {
            if c == .claudeCode {
                try await self.claude(["mcp", "remove", "--scope", "user", "cadence"])
            } else {
                try self.editConfig(c) { $0.map(MCPClientConfig.removing) }
            }
        }
    }

    /// Points every configured client at `helper` (after Cadence moved).
    func repoint(to helper: String) async {
        for c in AssistantClient.allCases where status[c]?.config != .missing {
            if c == .claudeCode {
                _ = try? await claude(["mcp", "remove", "--scope", "user", "cadence"])
                _ = try? await claude(["mcp", "add", "--scope", "user", "cadence", "--", helper])
            } else {
                try? editConfig(c) { MCPClientConfig.installing(into: $0, helperPath: helper) }
            }
        }
    }

    private func run(_ c: AssistantClient, _ work: @escaping () async throws -> Void) async {
        AssistantLog.write("\(c.name): start (helper \(self.helperPath))")
        busy.insert(c)
        lastError = nil
        defer { busy.remove(c); refresh() }
        do {
            try await work()
            AssistantLog.write("\(c.name): done")
        } catch {
            AssistantLog.write("\(c.name): failed: \(error.localizedDescription)")
            lastError = "\(c.name): \(error.localizedDescription)"
        }
    }

    /// Rewrites a JSON config, keeping a backup of the previous version next to it.
    private func editConfig(_ c: AssistantClient, _ change: (JSONValue?) -> JSONValue?) throws {
        let url = c.configURL
        let fm = FileManager.default
        let data = try? Data(contentsOf: url)
        let current = try MCPClientConfig.parse(data)
        guard let updated = change(current) else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data {
            try data.write(to: url.appendingPathExtension("cadence-backup"), options: .atomic)
        }
        try Data((updated.prettyString + "\n").utf8).write(to: url, options: .atomic)
    }

    // MARK: Claude Code CLI

    struct CLIError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func findClaudeCLI() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            claudeCLI = found
            return
        }
        // Fall back to the user's login shell PATH.
        let out = try? await Self.exec("/bin/zsh", ["-lc", "command -v claude"], path: nil)
        let path = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        claudeCLI = path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    @discardableResult
    private func claude(_ args: [String]) async throws -> String {
        guard let cli = claudeCLI else {
            throw CLIError(message: "Couldn't find the claude command. Run the command shown below in Terminal instead.")
        }
        return try await Self.exec(cli, args, path: (cli as NSString).deletingLastPathComponent)
    }

    /// Runs a command off the main thread; throws with its output when it fails.
    nonisolated static func exec(_ tool: String, _ args: [String], path extra: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                let base = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["PATH"] = [extra, base, env["PATH"]].compactMap { $0 }.joined(separator: ":")
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    if p.terminationStatus == 0 {
                        cont.resume(returning: text)
                    } else {
                        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(throwing: CLIError(message: msg.isEmpty ? "exited with \(p.terminationStatus)" : String(msg.prefix(300))))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Restart

    /// Quits the client and opens it again so it loads its MCP servers.
    func restart(_ c: AssistantClient) async {
        guard let id = c.bundleID, let url = appURL(c) else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        apps.forEach { $0.terminate() }
        for _ in 0..<40 where apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        refresh()
    }
}

/// Where Cadence runs from, and moving it to /Applications so assistant configs stay valid.
enum AppLocation {
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    static let destination = URL(fileURLWithPath: "/Applications/Cadence.app")

    static var destinationHelper: String { destination.appendingPathComponent("Contents/MacOS/cadence-mcp").path }

    /// Copies the app to /Applications (replacing any copy there), then relaunches from there.
    @MainActor
    static func moveToApplications(clients: AssistantClients) async throws {
        let source = Bundle.main.bundleURL.path
        let tmp = "/Applications/.Cadence-installing.app"
        _ = try await AssistantClients.exec("/bin/rm", ["-rf", tmp], path: nil)
        _ = try await AssistantClients.exec("/usr/bin/ditto", [source, tmp], path: nil)
        _ = try await AssistantClients.exec("/bin/rm", ["-rf", destination.path], path: nil)
        _ = try await AssistantClients.exec("/bin/mv", [tmp, destination.path], path: nil)
        await clients.repoint(to: destinationHelper)
        // Relaunch from the new copy once this one has quit.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
        try p.run()
        NSApp.terminate(nil)
    }
}
