import Foundation

/// Upper bounds on what one MCP server reply may put into memory and into the transcript.
public enum McpResponseLimit {
    /// Raw bytes accepted for a single JSON-RPC message (images included).
    public static let maxBytes = 8 * 1024 * 1024
    /// Text characters from one tool result that reach the model.
    public static let maxTextChars = 120_000

    public static func exceeds(bytes: Int) -> Bool { bytes > maxBytes }

    public static var tooLargeMessage: String {
        "MCP server reply exceeded \(maxBytes / 1_048_576) MB and was dropped. Ask the tool for a smaller page or a narrower query."
    }

    public static func clip(_ text: String) -> String {
        guard text.count > maxTextChars else { return text }
        return String(text.prefix(maxTextChars))
            + "\n…[tool result cut: \(text.count - maxTextChars) more characters. Ask for a narrower query or a specific page.]"
    }
}

public enum McpElicitationReply: Sendable {
    case accept([String: String])
    case decline
    case cancel
}

/// Lets an MCP server ask the person a question mid-call (`elicitation/create`).
/// With no handler installed the capability is not advertised and requests are declined.
public enum McpElicitation {
    public typealias Handler = @Sendable (_ message: String, _ fields: [McpElicitationField]) async -> McpElicitationReply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: Handler?

    public static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    public static var isEnabled: Bool { handler != nil }

    /// Flat string/number/boolean/enum properties from `requestedSchema`.
    public static func fields(from params: [String: Any]) -> [McpElicitationField] {
        let schema = params["requestedSchema"] as? [String: Any] ?? [:]
        let props = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return props.keys.sorted().map { key in
            let p = props[key] as? [String: Any] ?? [:]
            return McpElicitationField(
                key: key,
                title: p["title"] as? String ?? key,
                detail: p["description"] as? String ?? "",
                type: p["type"] as? String ?? "string",
                options: (p["enum"] as? [Any])?.map { "\($0)" } ?? [],
                required: required.contains(key)
            )
        }
    }

    /// JSON-RPC `result` for an `elicitation/create` request.
    public static func respond(params: [String: Any]) async -> [String: Any] {
        guard let handler else { return ["action": "decline"] }
        let message = params["message"] as? String ?? ""
        switch await handler(message, fields(from: params)) {
        case .decline: return ["action": "decline"]
        case .cancel: return ["action": "cancel"]
        case .accept(let values):
            let fields = fields(from: params)
            var content: [String: Any] = [:]
            for f in fields {
                guard let raw = values[f.key] else { continue }
                switch f.type {
                case "boolean": content[f.key] = ["true", "yes", "1"].contains(raw.lowercased())
                case "number", "integer": content[f.key] = Double(raw).map { f.type == "integer" ? Int($0) as Any : $0 as Any } ?? raw
                default: content[f.key] = raw
                }
            }
            return ["action": "accept", "content": content]
        }
    }
}

public struct McpElicitationField: Sendable, Equatable {
    public var key: String
    public var title: String
    public var detail: String
    public var type: String
    public var options: [String]
    public var required: Bool
}
