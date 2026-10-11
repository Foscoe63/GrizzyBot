import Foundation

/// Request building and stream parsing for the Anthropic Messages API.
public enum AnthropicWire {
    /// Largest output a request may ask for, by model family. Streaming and
    /// artifact-sized tool calls need far more than the old 4,096 cap.
    public static func maxTokens(for model: String) -> Int {
        let id = model.lowercased()
        if id.contains("claude-3-opus") || id.contains("claude-3-haiku") || id.contains("claude-2") { return 4_096 }
        if id.contains("claude-3-5") || id.contains("claude-3-sonnet") { return 8_192 }
        return 16_384
    }

    public static func body(for request: ChatCompletionRequest, stream: Bool) -> [String: Any] {
        let vision = LLMRouting.supportsVisionImages(
            provider: request.endpoint.provider,
            model: request.endpoint.model
        )
        var system = ""
        var turns: [(role: String, blocks: [[String: Any]])] = []
        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks.append(contentsOf: blocks)
            } else {
                turns.append((role, blocks))
            }
        }

        for message in ContextCompactor.repairToolPairs(request.messages) {
            switch message.role {
            case "system":
                if let content = message.content, !content.isEmpty {
                    system += (system.isEmpty ? "" : "\n\n") + content
                }
            case "tool":
                append("user", [[
                    "type": "tool_result",
                    "tool_use_id": message.toolCallId ?? "",
                    "content": (message.content?.isEmpty == false) ? message.content! : "(empty tool result)",
                ]])
            case "assistant":
                var blocks: [[String: Any]] = []
                if let text = message.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in message.toolCalls {
                    let parsed = JSONValue.parseObject(call.arguments)
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": parsed.isEmpty ? [String: Any]() : parsed.mapValues(\.any),
                    ])
                }
                append("assistant", blocks)
            default:
                var blocks: [[String: Any]] = []
                if let text = message.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                if vision, let jpeg = message.imageJPEGBase64, !jpeg.isEmpty {
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg],
                    ])
                }
                append("user", blocks)
            }
        }

        // Anthropic wants tool results ahead of any other content in a user turn.
        var messages: [[String: Any]] = turns.map { turn in
            let results = turn.blocks.filter { ($0["type"] as? String) == "tool_result" }
            let rest = turn.blocks.filter { ($0["type"] as? String) != "tool_result" }
            return ["role": turn.role, "content": results + rest]
        }
        // Cache everything up to the newest message on the next step.
        if var last = messages.last, var content = last["content"] as? [[String: Any]], !content.isEmpty {
            content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = content
            messages[messages.count - 1] = last
        }

        var body: [String: Any] = [
            "model": request.endpoint.model,
            "max_tokens": maxTokens(for: request.endpoint.model),
            "messages": messages,
        ]
        if stream { body["stream"] = true }
        if !system.isEmpty {
            body["system"] = [[
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"],
            ]]
        }
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = request.tools.map { tool in
                [
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "input_schema": tool.function.parameters.any,
                ]
            }
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = tools
        }
        return body
    }

    /// Input tokens include cache writes and reads so usage matches what was sent.
    public static func inputTokens(from usage: [String: Any]?) -> Int {
        func int(_ key: String) -> Int {
            if let n = usage?[key] as? Int { return n }
            if let n = usage?[key] as? Double { return Int(n) }
            return 0
        }
        return int("input_tokens") + int("cache_creation_input_tokens") + int("cache_read_input_tokens")
    }
}

/// Folds Anthropic server-sent events into one response.
public struct AnthropicStreamAccumulator: Sendable {
    public init() {}
    var text = ""
    var inputTokens = 0
    var outputTokens = 0
    var finishReason: String?
    private var blocks: [Int: (id: String, name: String, json: String)] = [:]
    private var errorMessage: String?

    /// Returns true once the stream is finished.
    public mutating func consume(line: String, onDelta: @escaping @Sendable (String) -> Void) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch json["type"] as? String ?? "" {
        case "message_start":
            let message = json["message"] as? [String: Any]
            inputTokens = AnthropicWire.inputTokens(from: message?["usage"] as? [String: Any])
            if let usage = message?["usage"] as? [String: Any], let out = usage["output_tokens"] as? Int {
                outputTokens = out
            }
        case "content_block_start":
            let index = json["index"] as? Int ?? 0
            let block = json["content_block"] as? [String: Any] ?? [:]
            if (block["type"] as? String) == "tool_use" {
                blocks[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
            }
        case "content_block_delta":
            let index = json["index"] as? Int ?? 0
            let delta = json["delta"] as? [String: Any] ?? [:]
            if let piece = delta["text"] as? String, (delta["type"] as? String) == "text_delta", !piece.isEmpty {
                text += piece
                onDelta(piece)
            } else if let partial = delta["partial_json"] as? String, var block = blocks[index] {
                block.json += partial
                blocks[index] = block
            }
        case "message_delta":
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                finishReason = reason
            }
            if let usage = json["usage"] as? [String: Any], let out = usage["output_tokens"] as? Int {
                outputTokens = out
            }
        case "error":
            let error = json["error"] as? [String: Any]
            errorMessage = error?["message"] as? String ?? "stream error"
            return true
        case "message_stop":
            return true
        default:
            break
        }
        return false
    }

    public func result() throws -> ChatCompletionResponse {
        if let errorMessage { throw LLMError.http(529, errorMessage) }
        let calls = blocks.keys.sorted().compactMap { index -> LLMToolCall? in
            guard let block = blocks[index], !block.name.isEmpty else { return nil }
            return LLMToolCall(
                id: block.id.isEmpty ? UUID().uuidString : block.id,
                name: block.name,
                arguments: block.json.isEmpty ? "{}" : block.json
            )
        }
        if text.isEmpty && calls.isEmpty { throw LLMError.emptyResponse }
        return ChatCompletionResponse(
            text: text,
            toolCalls: calls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            finishReason: finishReason
        )
    }
}
