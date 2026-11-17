import CadenceCore
import Foundation
import Observation

/// What assistants have done, kept for 30 days in Application Support/Cadence/mcp-activity.jsonl.
/// Local only; Settings → Assistants → Activity reads it.
@MainActor
@Observable
final class MCPActivityStore {
    private(set) var entries: [MCPActivityEntry] = []

    @ObservationIgnored private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-activity.jsonl")
    }()

    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    @ObservationIgnored private var added = 0

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let loaded = text.split(separator: "\n").compactMap { line -> MCPActivityEntry? in
            guard var e = try? decoder.decode(MCPActivityEntry.self, from: Data(line.utf8)) else { return nil }
            e.client = e.client.map(MCPClientNames.display)  // older entries kept raw clientInfo names
            return e
        }
        entries = MCPActivity.prune(loaded.sorted { $0.at < $1.at }, now: Date())
        if entries.count != loaded.count { rewrite() }
    }

    func add(_ entry: MCPActivityEntry) {
        entries.append(entry)
        if let data = try? encoder.encode(entry) {
            append(data + Data("\n".utf8))
        }
        added += 1
        if added % 200 == 0 {
            let pruned = MCPActivity.prune(entries, now: Date())
            if pruned.count != entries.count {
                entries = pruned
                rewrite()
            }
        }
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: file)
    }

    private func append(_ data: Data) {
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
    }

    private func rewrite() {
        let lines = entries.compactMap { try? encoder.encode($0) }.map { $0 + Data("\n".utf8) }
        try? lines.reduce(Data(), +).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}
