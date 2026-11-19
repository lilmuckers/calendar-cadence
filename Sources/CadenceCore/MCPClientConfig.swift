import Foundation

/// Adds, finds and removes Cadence's entry in an MCP client's JSON config
/// (`{"mcpServers": {"cadence": {"command": …}}}`), leaving everything else as it was.
public enum MCPClientConfig {
    public static let serverName = "cadence"

    public enum Status: Equatable, Sendable {
        case missing
        case current
        /// Configured, but pointing at another copy of the helper.
        case stale(String)
    }

    public struct InvalidConfig: LocalizedError, Sendable {
        public var errorDescription: String? { "The file isn't valid JSON (or isn't a JSON object), so Cadence won't change it." }
    }

    /// nil for a missing or empty file. Throws when the file has content that isn't a JSON object.
    public static func parse(_ data: Data?) throws -> JSONValue? {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.objectValue != nil else {
            throw InvalidConfig()
        }
        return value
    }

    public static func command(in config: JSONValue?) -> String? {
        config?["mcpServers"]?[serverName]?["command"]?.stringValue
    }

    public static func status(_ config: JSONValue?, helperPath: String) -> Status {
        guard let command = command(in: config) else { return .missing }
        return command == helperPath ? .current : .stale(command)
    }

    public static func installing(into config: JSONValue?, helperPath: String) -> JSONValue {
        var root = config?.objectValue ?? [:]
        var servers = root["mcpServers"]?.objectValue ?? [:]
        var entry = servers[serverName]?.objectValue ?? [:]
        entry["command"] = .string(helperPath)
        entry["args"] = entry["args"] ?? []
        servers[serverName] = .object(entry)
        root["mcpServers"] = .object(servers)
        return .object(root)
    }

    public static func removing(from config: JSONValue) -> JSONValue {
        guard var root = config.objectValue, var servers = root["mcpServers"]?.objectValue else { return config }
        servers[serverName] = nil
        root["mcpServers"] = .object(servers)
        return .object(root)
    }
}

/// Friendly names for the `clientInfo` names MCP clients report.
public enum MCPClientNames {
    public static func display(_ raw: String) -> String {
        let n = raw.lowercased()
        if n == "claude-ai" || n == "claude" { return "Claude" }
        if n.hasPrefix("local-agent-mode") { return "Claude (Code tab)" }
        if n.hasPrefix("claude-code") || n == "claude code" { return "Claude Code" }
        if n.hasPrefix("cursor") { return "Cursor" }
        if n.hasPrefix("windsurf") { return "Windsurf" }
        return raw
    }

    /// One entry per assistant, with a count when several sessions of it are connected
    /// (e.g. "Claude Code ×12, Claude"). Order follows first connection.
    public static func summary(_ names: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in names {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { n in counts[n]! > 1 ? "\(n) ×\(counts[n]!)" : n }.joined(separator: ", ")
    }
}
