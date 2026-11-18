import Foundation

/// The other wire formats the local gateway speaks, so Claude-, Codex- and Ollama-style clients can talk
/// to a bot. Each parser turns a request body into plain chat messages; each formatter wraps the bot's
/// reply the way that API expects. Replies are returned whole, not token by token.
public enum GatewayProtocols {
    public struct Parsed: Equatable {
        public var model: String?
        public var messages: [[String: String]]
    }

    /// Text of a content value that is either a string or an array of typed blocks.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            let type = block["type"] as? String
            if type == nil || type == "text" || type == "input_text" || type == "output_text" { return block["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: Anthropic /v1/messages

    public static func parseAnthropic(_ json: [String: Any]) -> Parsed {
        var messages: [[String: String]] = []
        let system = text(of: json["system"])
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for row in (json["messages"] as? [[String: Any]]) ?? [] {
            guard let role = row["role"] as? String else { continue }
            let body = text(of: row["content"])
            if !body.isEmpty { messages.append(["role": role, "content": body]) }
        }
        return Parsed(model: json["model"] as? String, messages: messages)
    }

    public static func anthropicReply(_ reply: String, model: String) -> [String: Any] {
        [
            "id": "msg_\(UUID().uuidString.prefix(12))", "type": "message", "role": "assistant", "model": model,
            "content": [["type": "text", "text": reply]],
            "stop_reason": "end_turn", "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": max(1, reply.count / 4)],
        ]
    }

    // MARK: Open Responses /v1/responses

    public static func parseResponses(_ json: [String: Any]) -> Parsed {
        var messages: [[String: String]] = []
        if let instructions = json["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        if let input = json["input"] as? String {
            messages.append(["role": "user", "content": input])
        } else if let items = json["input"] as? [[String: Any]] {
            for item in items {
                let role = (item["role"] as? String) ?? "user"
                let body = text(of: item["content"])
                if !body.isEmpty { messages.append(["role": role == "developer" ? "system" : role, "content": body]) }
            }
        }
        return Parsed(model: json["model"] as? String, messages: messages)
    }

    public static func responsesReply(_ reply: String, model: String) -> [String: Any] {
        let id = UUID().uuidString.prefix(12)
        return [
            "id": "resp_\(id)", "object": "response", "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed", "model": model,
            "output": [[
                "id": "msg_\(id)", "type": "message", "role": "assistant", "status": "completed",
                "content": [["type": "output_text", "text": reply, "annotations": [Any]()]],
            ]],
            "usage": ["input_tokens": 0, "output_tokens": max(1, reply.count / 4), "total_tokens": max(1, reply.count / 4)],
        ]
    }

    // MARK: Ollama /api/chat

    public static func parseOllama(_ json: [String: Any]) -> Parsed {
        let messages = ((json["messages"] as? [[String: Any]]) ?? []).compactMap { row -> [String: String]? in
            guard let role = row["role"] as? String, let content = row["content"] as? String else { return nil }
            return ["role": role, "content": content]
        }
        return Parsed(model: json["model"] as? String, messages: messages)
    }

    public static func ollamaReply(_ reply: String, model: String) -> [String: Any] {
        [
            "model": model, "created_at": ISO8601DateFormatter().string(from: .now),
            "message": ["role": "assistant", "content": reply], "done": true, "done_reason": "stop",
        ]
    }

    public static func ollamaTags(bots: [(id: String, name: String)]) -> [String: Any] {
        ["models": bots.map { ["name": "grizzybot/\($0.id)", "model": "grizzybot/\($0.id)", "details": ["family": "grizzybot", "name": $0.name]] as [String: Any] }]
    }

    // MARK: /agents/{id}/run (server-sent events)

    /// `POST /agents/{botId}/run` → the bot id in the path, or nil when the path is not that shape.
    public static func agentRunBotId(path: String) -> String? {
        let parts = path.split(separator: "?").first.map(String.init)?.split(separator: "/").map(String.init) ?? []
        guard parts.count == 3, parts[0] == "agents", parts[2] == "run", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    public static func agentRunPrompt(_ json: [String: Any]) -> String {
        if let prompt = json["prompt"] as? String { return prompt }
        if let input = json["input"] as? String { return input }
        let parsed = parseOllama(json)
        return parsed.messages.last(where: { $0["role"] == "user" })?["content"] ?? ""
    }

    /// The event stream body: the reply as one text event, a completion event, then `[DONE]`.
    public static func sse(reply: String) -> String {
        func event(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "data: \(data)\n\n"
        }
        return event(["type": "text", "text": reply]) + event(["type": "complete"]) + "data: [DONE]\n\n"
    }
}
