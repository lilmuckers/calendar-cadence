import Foundation

/// Settings → General → Export / Import: a `.cadconf` file, which is YAML:
///
///     # Cadence settings
///     format: cadence-settings
///     version: 1
///     settings:
///       takeoverEnabled: true
///       ...
///
/// `settings` holds the app's preferences under their stored names. Importing lays the file's
/// top-level settings over the current ones, so a file that leaves something out (an older
/// export, or one trimmed by hand) keeps what's already set for it.
public enum SettingsArchive {
    public static let fileExtension = "cadconf"
    public static let format = "cadence-settings"
    /// Bump when a change means older builds would misread the file.
    public static let version = 1

    public enum ArchiveError: Error, LocalizedError, Equatable {
        case notYAML(String)
        case notSettings
        case newerVersion(Int)
        case badValue(String)

        public var errorDescription: String? {
            switch self {
            case .notYAML(let why): "This isn't a readable settings file. \(why)"
            case .notSettings: "This isn't a Cadence settings file (it has no \"format: \(SettingsArchive.format)\" line)."
            case .newerVersion(let v): "This file was made by a newer Cadence (settings version \(v)). Update Cadence to import it."
            case .badValue(let why): "A setting in this file has the wrong kind of value: \(why)"
            }
        }
    }

    /// The file's text. `omitting` drops top-level settings (by stored name); `comments` become
    /// `#` lines at the top.
    public static func export<T: Encodable>(_ settings: T, omitting: Set<String> = [], comments: [String] = []) throws -> String {
        var dict = try jsonObject(settings)
        for key in omitting { dict[key] = nil }
        var out = comments.map { $0.isEmpty ? "#" : "# \($0)" }.joined(separator: "\n")
        if !out.isEmpty { out += "\n\n" }
        out += "format: \(format)\nversion: \(version)\n"
        if dict.isEmpty {
            out += "settings: {}\n"
        } else {
            out += "settings:\n"
            for line in YAML.encode(dict).split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                out += "  \(line)\n"
            }
        }
        return out
    }

    public struct Imported<T> {
        public let settings: T
        /// The top-level settings the file set, sorted.
        public let keys: [String]
        /// The file's raw top-level settings, for callers that want to look before applying.
        public let raw: [String: Any]
    }

    /// Reads a file and lays its settings over `current`.
    public static func read<T: Codable>(_ text: String, over current: T) throws -> Imported<T> {
        let root: Any
        do { root = try YAML.decode(text) } catch let error as YAML.ParseError {
            throw ArchiveError.notYAML(error.localizedDescription)
        }
        guard let dict = root as? [String: Any], dict["format"] as? String == format else { throw ArchiveError.notSettings }
        if let v = (dict["version"] as? NSNumber)?.intValue, v > version { throw ArchiveError.newerVersion(v) }
        let incoming: [String: Any]
        switch dict["settings"] {
        case nil, is NSNull: incoming = [:]
        case let d as [String: Any]: incoming = d
        default: throw ArchiveError.badValue("\"settings\" should be a list of settings")
        }

        var merged = try jsonObject(current)
        for (key, value) in incoming { merged[key] = value }
        // JSONSerialization raises (rather than throws) on values JSON can't hold.
        guard JSONSerialization.isValidJSONObject(merged) else { throw ArchiveError.badValue("a value can't be read") }
        let data = try JSONSerialization.data(withJSONObject: merged)
        do {
            let settings = try JSONDecoder().decode(T.self, from: data)
            return Imported(settings: settings, keys: incoming.keys.sorted(), raw: incoming)
        } catch let error as DecodingError {
            throw ArchiveError.badValue(describe(error))
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ c: [CodingKey]) -> String {
            c.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .typeMismatch(let type, let ctx): return "\(path(ctx.codingPath)) should be \(kind(type))."
        case .valueNotFound(let type, let ctx): return "\(path(ctx.codingPath)) needs \(kind(type))."
        case .keyNotFound(let key, let ctx): return "\(path(ctx.codingPath + [key])) is missing."
        case .dataCorrupted(let ctx):
            return ctx.codingPath.isEmpty ? ctx.debugDescription : "\(path(ctx.codingPath)) isn't one of the allowed values."
        @unknown default: return error.localizedDescription
        }
    }

    private static func kind(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: "true or false"
        case is Int.Type, is Double.Type: "a number"
        case is String.Type: "text"
        default:
            String(describing: type).hasPrefix("Array") || String(describing: type).hasPrefix("Set") ? "a list" : "a group of settings"
        }
    }
}
