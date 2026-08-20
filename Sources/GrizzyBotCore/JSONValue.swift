import Foundation

/// JSON value used for tool schemas and LLM payloads (Sendable, unlike `Any`).
public enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, let int = Int(exactly: value) {
                try container.encode(int)
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var any: Any {
        switch self {
        case .object(let object): return object.mapValues(\.any)
        case .array(let array): return array.map(\.any)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case let value as JSONValue:
            return value
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Float:
            return .number(Double(value))
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from))
        default:
            return .string(String(describing: any))
        }
    }

    public func stringValue(_ key: String? = nil) -> String? {
        let value: JSONValue = {
            if let key, case .object(let object) = self { return object[key] ?? .null }
            return self
        }()
        switch value {
        case .string(let string): return string
        case .number(let number):
            if number.rounded() == number { return String(Int(number)) }
            return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return nil
        default: return nil
        }
    }

    public func objectValue() -> [String: JSONValue] {
        if case .object(let object) = self { return object }
        return [:]
    }

    public func jsonString(pretty: Bool = false) -> String {
        guard let data = try? JSONEncoder.compact.encode(self) else {
            return "{}"
        }
        if pretty, let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: prettyData, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func parseObject(_ raw: String) -> [String: JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return [:]
        }
        return decoded.objectValue()
    }

    /// Shallow object merge used for AG-UI `STATE_DELTA`. Arrays and scalars replace.
    public func merging(_ delta: JSONValue) -> JSONValue {
        guard case .object(let base) = self, case .object(let patch) = delta else {
            return delta
        }
        var next = base
        for (key, value) in patch {
            if let existing = next[key] {
                next[key] = existing.merging(value)
            } else {
                next[key] = value
            }
        }
        return .object(next)
    }
}

extension JSONEncoder {
    static var compact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
