import Foundation

/// Any JSON value. Used for MCP's JSON-RPC payloads, whose shapes vary per method.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Converts any Encodable (e.g. a DTO) into a JSONValue.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONValue.encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Compact single-line JSON.
    public var jsonString: String {
        (try? JSONValue.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Indented JSON for text content shown to a model.
    public var prettyString: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func parse(_ line: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// JSON-RPC 2.0 helpers for newline-delimited MCP messages.
public enum JSONRPC {
    public static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    public static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    public static func notification(_ method: String, params: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
}
