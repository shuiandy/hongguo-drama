import Foundation

/// A small dynamic JSON tree. Upstream pages embed loosely typed JSON whose fields
/// change between releases, so parsing goes through this instead of strict Codable models.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: raw)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let dict) = self { return dict[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var object: [String: JSONValue]? { if case .object(let d) = self { return d }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }

    /// Only a real JSON string.
    public var string: String? { if case .string(let s) = self { return s }; return nil }

    /// Trimmed non-empty JSON string; returns `nil` for `""` or whitespace-only strings.
    public var nonEmptyString: String? {
        guard let raw = string else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A string, or an integer rendered as text. Upstream ids appear as either.
    public var idString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return String(Int64(d))
        default: return nil
        }
    }

    /// Non-empty `idString` that is not all-zeros (e.g. `"0"`).
    public var nonZeroIdString: String? {
        guard let raw = idString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.contains(where: { $0 != "0" }) else { return nil }
        return raw
    }

    /// Safe signed integer from int, finite bounded double, or trimmed numeric string.
    public var signedInt: Int? {
        switch self {
        case .int(let i):
            return Int(exactly: i)
        case .double(let d) where d.isFinite && abs(d) < 9.0e15:
            return Int(d)
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed), d.isFinite, d.rounded() == d, abs(d) < 9.0e15 { return Int(d) }
            return nil
        default:
            return nil
        }
    }

    /// True when the field is absent/null or explicitly represents status code `0` (`0`, `0.0`, `"0"`).
    public var isZeroOrMissingStatusCode: Bool {
        if isNull { return true }
        return signedInt == 0
    }

    /// Numeric value from a number or a numeric string.
    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
