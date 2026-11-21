import Foundation

/// A small YAML reader and writer for settings files, working on the same values
/// `JSONSerialization` produces: `[String: Any]`, `[Any]`, `String`, `NSNumber` (numbers and
/// booleans) and `NSNull`.
///
/// It writes block-style YAML and reads the common subset people write by hand: block mappings
/// and sequences (including `- key: value` items), `#` comments, plain / single-quoted /
/// double-quoted scalars, `true`/`false`/`null`/`~`, numbers, and one-line flow collections such as
/// `[a, b]` or `{}`. Anchors, tags, multi-document streams and block scalars (`|`, `>`) aren't
/// supported and are reported as errors rather than misread.
public enum YAML {
    public struct ParseError: Error, LocalizedError, Equatable {
        public let line: Int
        public let message: String
        public var errorDescription: String? { "Line \(line): \(message)" }
    }

    // MARK: - Writing

    /// YAML for a JSON-style value. Mapping keys are written in sorted order.
    public static func encode(_ value: Any) -> String {
        var out = ""
        if isCollection(value), !isEmptyCollection(value) {
            writeBlock(value, indent: 0, into: &out)
        } else {
            out = scalar(value) + "\n"
        }
        return out
    }

    private static func writeBlock(_ value: Any, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() {
                let child = dict[key]!
                if isCollection(child), !isEmptyCollection(child) {
                    out += "\(pad)\(keyText(key)):\n"
                    // Sequences sit under their key indented, which reads better than YAML's flush style.
                    writeBlock(child, indent: indent + 2, into: &out)
                } else {
                    out += "\(pad)\(keyText(key)): \(scalar(child))\n"
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let dict = item as? [String: Any], !dict.isEmpty {
                    // "- first: 1\n  second: 2": the item's keys line up after the dash.
                    var inner = ""
                    writeBlock(dict, indent: indent + 2, into: &inner)
                    out += pad + "- " + inner.dropFirst(indent + 2)
                } else if let nested = item as? [Any], !nested.isEmpty {
                    out += "\(pad)-\n"
                    writeBlock(nested, indent: indent + 2, into: &out)
                } else {
                    out += "\(pad)- \(scalar(item))\n"
                }
            }
        }
    }

    private static func isCollection(_ v: Any) -> Bool { v is [String: Any] || v is [Any] }

    private static func isEmptyCollection(_ v: Any) -> Bool {
        if let d = v as? [String: Any] { return d.isEmpty }
        if let a = v as? [Any] { return a.isEmpty }
        return false
    }

    private static func keyText(_ key: String) -> String {
        let plain = !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        } && !key.hasPrefix("-") && !looksSpecial(key)
        return plain ? key : quoted(key)
    }

    /// Plain text YAML would read as something other than a string.
    private static func looksSpecial(_ s: String) -> Bool {
        if case .some = keyword(s) { return true }
        return number(s) != nil
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let d as [String: Any] where d.isEmpty: return "{}"
        case let a as [Any] where a.isEmpty: return "[]"
        case let s as String: return quoted(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let type = String(cString: n.objCType)
            if ["f", "d"].contains(type) {
                let d = n.doubleValue
                if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
                return "\(d)"
            }
            return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return "\(d)"
        default: return quoted(String(describing: value))
        }
    }

    /// A double-quoted scalar. JSON string escapes are valid YAML double-quoted escapes.
    private static func quoted(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    // MARK: - Reading

    private struct Line {
        let number: Int
        var indent: Int
        var text: String
    }

    /// The JSON-style value a YAML document describes. An empty document is `NSNull`.
    public static func decode(_ text: String) throws -> Any {
        var lines: [Line] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            if raw.hasPrefix("%") { throw ParseError(line: i + 1, message: "YAML directives aren't supported") }
            if raw == "---" && lines.isEmpty { continue }
            if raw == "---" || raw == "..." { throw ParseError(line: i + 1, message: "Only one YAML document is supported") }
            if raw.contains("\t") && raw.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw ParseError(line: i + 1, message: "Indent with spaces, not tabs")
            }
            let content = stripComment(raw)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = content.prefix(while: { $0 == " " }).count
            lines.append(Line(number: i + 1, indent: indent, text: trimmed))
        }
        guard !lines.isEmpty else { return NSNull() }
        var parser = Parser(lines: lines)
        let value = try parser.node(indent: lines[0].indent)
        if parser.index < lines.count {
            throw ParseError(line: lines[parser.index].number, message: "Unexpected indentation")
        }
        return value
    }

    private struct Parser {
        var lines: [Line]
        var index = 0

        mutating func node(indent: Int) throws -> Any {
            let line = lines[index]
            if isSequenceItem(line.text) { return try sequence(indent: indent) }
            if splitKey(line.text) != nil { return try mapping(indent: indent) }
            index += 1
            return try YAML.value(line.text, line: line.number)
        }

        mutating func mapping(indent: Int) throws -> [String: Any] {
            var dict: [String: Any] = [:]
            while index < lines.count, lines[index].indent == indent, !isSequenceItem(lines[index].text) {
                let line = lines[index]
                guard let (key, rest) = splitKey(line.text) else {
                    throw ParseError(line: line.number, message: "Expected \"key: value\"")
                }
                let name = try YAML.keyName(key, line: line.number)
                if dict[name] != nil { throw ParseError(line: line.number, message: "\"\(name)\" appears twice") }
                index += 1
                if rest.isEmpty {
                    if index < lines.count, lines[index].indent > indent {
                        dict[name] = try node(indent: lines[index].indent)
                    } else if index < lines.count, lines[index].indent == indent, isSequenceItem(lines[index].text) {
                        dict[name] = try sequence(indent: indent)   // "key:\n- a\n- b"
                    } else {
                        dict[name] = NSNull()
                    }
                } else {
                    dict[name] = try YAML.value(rest, line: line.number)
                    if index < lines.count, lines[index].indent > indent {
                        throw ParseError(line: lines[index].number, message: "Unexpected indentation")
                    }
                }
            }
            return dict
        }

        mutating func sequence(indent: Int) throws -> [Any] {
            var array: [Any] = []
            while index < lines.count, lines[index].indent == indent, isSequenceItem(lines[index].text) {
                let line = lines[index]
                let rest = String(line.text.dropFirst()).drop(while: { $0 == " " })
                if rest.isEmpty {
                    index += 1
                    if index < lines.count, lines[index].indent > indent {
                        array.append(try node(indent: lines[index].indent))
                    } else {
                        array.append(NSNull())
                    }
                } else if isSequenceItem(String(rest)) || splitKey(String(rest)) != nil {
                    // "- key: value" or "- - x": the rest of the line starts a nested block whose
                    // indent is where its text begins.
                    let childIndent = indent + (line.text.count - rest.count)
                    lines[index] = Line(number: line.number, indent: childIndent, text: String(rest))
                    array.append(try node(indent: childIndent))
                } else {
                    index += 1
                    array.append(try YAML.value(String(rest), line: line.number))
                    if index < lines.count, lines[index].indent > indent {
                        throw ParseError(line: lines[index].number, message: "Unexpected indentation")
                    }
                }
            }
            return array
        }
    }

    private static func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    /// "key: rest" split at the first colon that's followed by a space or the end, outside quotes.
    private static func splitKey(_ text: String) -> (String, String)? {
        let chars = Array(text)
        guard let first = chars.first, first != "[", first != "{" else { return nil }
        var i = 0
        if first == "\"" || first == "'" {
            guard let end = closingQuote(chars, from: 0) else { return nil }
            i = end + 1
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count, chars[i] == ":" else { return nil }
        } else {
            while i < chars.count {
                if chars[i] == ":", i + 1 == chars.count || chars[i + 1] == " " { break }
                i += 1
            }
            guard i < chars.count else { return nil }
        }
        let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
        let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    private static func closingQuote(_ chars: [Character], from start: Int) -> Int? {
        let q = chars[start]
        var i = start + 1
        while i < chars.count {
            if q == "\"", chars[i] == "\\" { i += 2; continue }
            if chars[i] == q {
                if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    /// The line without a trailing `# comment` (a `#` at the start or after a space, outside quotes).
    private static func stripComment(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                // Only quotes that open a scalar count; an apostrophe inside plain text doesn't.
                let opens = i == 0 || [" ", ":", "-", "[", "{", ","].contains(chars[i - 1])
                if opens, let end = closingQuote(chars, from: i) { i = end + 1; continue }
            }
            if c == "#", i == 0 || chars[i - 1] == " " { return String(chars[..<i]) }
            i += 1
        }
        return line
    }

    private static func keyName(_ key: String, line: Int) throws -> String {
        if key.hasPrefix("\"") || key.hasPrefix("'") {
            guard let s = try value(key, line: line) as? String else {
                throw ParseError(line: line, message: "Bad key \(key)")
            }
            return s
        }
        if key.isEmpty { throw ParseError(line: line, message: "Missing key") }
        return key
    }

    private enum Keyword { case null, bool(Bool) }

    private static func keyword(_ s: String) -> Keyword? {
        switch s {
        case "null", "Null", "NULL", "~": Keyword.null
        case "true", "True", "TRUE": Keyword.bool(true)
        case "false", "False", "FALSE": Keyword.bool(false)
        default: nil
        }
    }

    private static func number(_ s: String) -> NSNumber? {
        let isInt = s.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil
        if isInt, let i = Int(s) { return NSNumber(value: i) }
        let isFloat = s.range(of: #"^[-+]?([0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
        if isFloat, let d = Double(s) { return NSNumber(value: d) }
        return nil
    }

    /// One scalar or one-line flow collection.
    private static func value(_ text: String, line: Int) throws -> Any {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return NSNull() }
        switch first {
        case "\"":
            guard let end = closingQuote(Array(s), from: 0), end == s.count - 1 else {
                throw ParseError(line: line, message: "Unclosed or misplaced quote")
            }
            guard let data = s.data(using: .utf8),
                  let str = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                throw ParseError(line: line, message: "Bad escape in \(s)")
            }
            return str
        case "'":
            guard let end = closingQuote(Array(s), from: 0), end == s.count - 1 else {
                throw ParseError(line: line, message: "Unclosed or misplaced quote")
            }
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        case "[":
            guard s.last == "]" else { throw ParseError(line: line, message: "Unclosed [") }
            return try flowItems(String(s.dropFirst().dropLast()), line: line).map { try value($0, line: line) }
        case "{":
            guard s.last == "}" else { throw ParseError(line: line, message: "Unclosed {") }
            var dict: [String: Any] = [:]
            for item in try flowItems(String(s.dropFirst().dropLast()), line: line) {
                guard let (k, v) = splitKey(item) else { throw ParseError(line: line, message: "Expected \"key: value\" in {…}") }
                dict[try keyName(k, line: line)] = v.isEmpty ? NSNull() : try value(v, line: line)
            }
            return dict
        case "&", "*", "!", "|", ">", "@", "`":
            throw ParseError(line: line, message: "\(first) isn't supported here; quote the value")
        default:
            if let k = keyword(s) {
                switch k {
                case .null: return NSNull()
                case .bool(let b): return NSNumber(value: b)
                }
            }
            if let n = number(s) { return n }
            return s
        }
    }

    /// Comma-separated items of a flow collection, respecting quotes and nesting.
    private static func flowItems(_ body: String, line: Int) throws -> [String] {
        let chars = Array(body)
        var items: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                guard let end = closingQuote(chars, from: i) else { throw ParseError(line: line, message: "Unclosed quote") }
                i = end + 1
                continue
            }
            if c == "[" || c == "{" { depth += 1 }
            if c == "]" || c == "}" { depth -= 1 }
            if c == ",", depth == 0 {
                items.append(String(chars[start..<i]))
                start = i + 1
            }
            i += 1
        }
        items.append(String(chars[start...]))
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.count == 1, trimmed[0].isEmpty { return [] }
        if trimmed.last == "" { return Array(trimmed.dropLast()) }   // trailing comma
        return trimmed
    }
}
