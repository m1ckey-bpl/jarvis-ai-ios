import Foundation

/// A type-erased, `Codable` JSON value.
///
/// Used wherever the engine must handle model- or service-supplied JSON whose
/// shape is not known at compile time (tool arguments, tool results, provider
/// payloads). Keeps `JarvisCore` free of `Any`-based hacks and makes argument
/// validation deterministic.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Accessors

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased())
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Compact, stable representation for logs and prompts.
    public var jsonString: String {
        guard let data = try? JSONEncoder.jarvis.encode(self) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Renders any `Encodable` into a `JSONValue`.
    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONEncoder.jarvis.encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
    }
}

public extension JSONEncoder {
    /// Encoder configured for deterministic output across the engine.
    static let jarvis: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

public extension JSONDecoder {
    static let jarvis = JSONDecoder()
}

public extension JSONValue {
    /// Convenience for building objects in tests and fixtures.
    static func obj(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}
