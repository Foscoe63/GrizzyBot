import Foundation

/// What a local model's raw output decomposes into.
public struct MLXParsedOutput: Sendable, Equatable {
    /// Visible assistant text, with reasoning and tool envelopes removed.
    public var text: String
    /// Content of `<think>` / `<reasoning>` blocks, kept out of the answer.
    public var reasoning: String
    public var toolCalls: [LLMToolCall]

    public init(text: String, reasoning: String = "", toolCalls: [LLMToolCall] = []) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
    }
}

/// Recovers tool calls from a local model's plain text.
///
/// An OpenAI-compatible server does this for us; running MLX in-process means
/// GrizzyBot sees the raw decoded string, and every model family spells tool
/// calls differently. The envelopes handled here are the ones the common MLX
/// chat templates emit:
///
/// - `<tool_call>{"name": …, "arguments": {…}}</tool_call>` — Qwen, Hermes, GLM
/// - `[TOOL_CALLS] [{"name": …, "arguments": {…}}]` — Mistral
/// - a fenced ```json block holding the same object — many fine-tunes
/// - a bare top-level JSON object or array with `name` + `arguments`
///
/// Anything that does not parse is left in `text` rather than dropped, so a
/// model that merely *talks* about a tool still shows its answer.
public enum MLXToolCallParser {
    public static func parse(_ raw: String) -> MLXParsedOutput {
        var working = raw
        let reasoning = extractReasoning(from: &working)

        var calls: [LLMToolCall] = []
        calls += extractTagged(from: &working, open: "<tool_call>", close: "</tool_call>")
        calls += extractTagged(from: &working, open: "<tool_call>", close: "<\\/tool_call>")
        calls += extractMistral(from: &working)
        calls += extractFencedJSON(from: &working)

        var text = working.trimmingCharacters(in: .whitespacesAndNewlines)
        if calls.isEmpty, let bare = parseBareJSON(text) {
            calls = bare
            text = ""
        }

        return MLXParsedOutput(
            text: text,
            reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: renumber(calls)
        )
    }

    // MARK: - Reasoning

    private static let reasoningTags = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
    ]

    private static func extractReasoning(from text: inout String) -> String {
        var collected: [String] = []
        for (open, close) in reasoningTags {
            while let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                collected.append(String(text[start.upperBound..<end.lowerBound]))
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
            // An unterminated block means generation stopped mid-thought; keep
            // it as reasoning rather than leaking a half-open tag to the user.
            if let start = text.range(of: open) {
                collected.append(String(text[start.upperBound...]))
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        return collected.joined(separator: "\n")
    }

    // MARK: - Envelopes

    private static func extractTagged(
        from text: inout String,
        open: String,
        close: String
    ) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []
        while let start = text.range(of: open) {
            guard let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
                // Truncated envelope: try the remainder, then stop.
                let body = String(text[start.upperBound...])
                calls += decodeCalls(from: body)
                text.removeSubrange(start.lowerBound..<text.endIndex)
                break
            }
            let body = String(text[start.upperBound..<end.lowerBound])
            calls += decodeCalls(from: body)
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return calls
    }

    private static func extractMistral(from text: inout String) -> [LLMToolCall] {
        let marker = "[TOOL_CALLS]"
        guard let start = text.range(of: marker) else { return [] }
        let body = String(text[start.upperBound...])
        let calls = decodeCalls(from: body)
        guard !calls.isEmpty else { return [] }
        text.removeSubrange(start.lowerBound..<text.endIndex)
        return calls
    }

    private static func extractFencedJSON(from text: inout String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []
        let fences = ["```json", "```tool_call", "```"]
        for fence in fences {
            while let start = text.range(of: fence) {
                guard let end = text.range(of: "```", range: start.upperBound..<text.endIndex) else { break }
                let body = String(text[start.upperBound..<end.lowerBound])
                let decoded = decodeCalls(from: body)
                guard !decoded.isEmpty else { break }
                calls += decoded
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return calls
    }

    private static func parseBareJSON(_ text: String) -> [LLMToolCall]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        let calls = decodeCalls(from: trimmed)
        return calls.isEmpty ? nil : calls
    }

    // MARK: - JSON decoding

    /// Pull every `{name, arguments}` object out of `body`, tolerating the
    /// prose models often wrap around it.
    private static func decodeCalls(from body: String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []
        for candidate in jsonCandidates(in: body) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            calls += toolCalls(from: object)
        }
        return calls
    }

    private static func toolCalls(from object: Any) -> [LLMToolCall] {
        if let array = object as? [Any] {
            return array.flatMap { toolCalls(from: $0) }
        }
        guard let dict = object as? [String: Any] else { return [] }

        // OpenAI shape: {"function": {"name": …, "arguments": …}}
        if let function = dict["function"] as? [String: Any] {
            return toolCalls(from: function)
        }
        let rawName = (dict["name"] as? String) ?? (dict["tool_name"] as? String)
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return []
        }
        let rawArguments = dict["arguments"] ?? dict["parameters"] ?? dict["args"]
        return [
            LLMToolCall(id: "", name: name, arguments: encodeArguments(rawArguments)),
        ]
    }

    /// Arguments reach us as either a JSON object or an already-encoded string.
    /// The rest of GrizzyBot expects a JSON string, so normalize to that.
    private static func encodeArguments(_ raw: Any?) -> String {
        guard let raw else { return "{}" }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "{}" : trimmed
        }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let encoded = String(data: data, encoding: .utf8)
        else { return "{}" }
        return encoded
    }

    /// Every balanced `{…}` or `[…]` run in `text`, ignoring braces inside
    /// string literals so an argument value containing `}` does not truncate
    /// the candidate.
    static func jsonCandidates(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{", "[":
                if depth == 0 { start = index }
                depth += 1
            case "}", "]":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let from = start {
                    results.append(String(text[from...index]))
                    start = nil
                }
            default:
                continue
            }
        }
        return results
    }

    /// Give every call a stable, unique id — local models rarely emit one.
    private static func renumber(_ calls: [LLMToolCall]) -> [LLMToolCall] {
        calls.enumerated().map { index, call in
            LLMToolCall(
                id: call.id.isEmpty ? "mlx_call_\(index + 1)" : call.id,
                name: call.name,
                arguments: call.arguments
            )
        }
    }
}
