import Foundation
import GrizzyBotCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs an MLX model on this Mac's GPU.
///
/// One model is resident at a time: loading a second multi-gigabyte set of
/// weights beside the first is the fastest way to exhaust unified memory, so a
/// request for a different bundle unloads the current one first. Generation is
/// serialized behind the actor for the same reason — MLX's Metal stream is not
/// safe to drive from two turns at once.
public actor MLXLocalGenerator: MLXTextGenerating {
    public static let shared = MLXLocalGenerator()

    private var loadedPath: String?
    private var container: ModelContainer?

    /// Fraction of physical memory MLX's buffer cache may hold. Left modest so
    /// a resident model does not squeeze the rest of the machine.
    private static let cacheLimitFraction = 0.5

    public init() {}

    // MARK: - Model residency

    private func container(for url: URL) async throws -> ModelContainer {
        let path = url.standardizedFileURL.path
        if let container, loadedPath == path {
            return container
        }
        // Drop the previous model's weights before allocating the next one's.
        if container != nil {
            self.container = nil
            loadedPath = nil
            MLX.Memory.clearCache()
        }

        MLX.Memory.cacheLimit = Int(
            Double(ProcessInfo.processInfo.physicalMemory) * Self.cacheLimitFraction
        )

        let loaded = try await loadModelContainer(
            from: url,
            using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        loadedPath = path
        return loaded
    }

    public func unload() {
        container = nil
        loadedPath = nil
        MLX.Memory.clearCache()
    }

    /// The bundle currently resident, for status display.
    public var residentModelPath: String? { loadedPath }

    // MARK: - Generation

    public func generate(
        _ request: MLXGenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> MLXGenerationResult {
        let container = try await container(for: request.bundleURL)

        let input = UserInput(
            chat: Self.chatMessages(from: request.messages),
            tools: Self.toolSpecs(from: request.tools)
        )
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            repetitionPenalty: request.repetitionPenalty
        )

        let prepared = try await container.prepare(input: input)
        let stream = try await container.generate(input: prepared, parameters: parameters)

        var text = ""
        // Tool calls the runtime recognized itself. When the model's template
        // is one MLX understands these arrive structured, and are strictly
        // better than re-parsing the decoded text — `MLXToolCallParser` stays
        // as the fallback for everything else.
        var nativeCalls: [LLMToolCall] = []
        var promptTokens = 0
        var generatedTokens = 0
        var finishReason: String?

        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let chunk):
                text += chunk
                onDelta(chunk)
            case .toolCall(let call):
                nativeCalls.append(Self.toolCall(from: call, index: nativeCalls.count))
            case .info(let info):
                promptTokens = info.promptTokenCount
                generatedTokens = info.generationTokenCount
                finishReason = Self.finishReason(from: info)
            @unknown default:
                // A future event kind: the raw text is already accumulated, so
                // `MLXToolCallParser` still gets its chance at it.
                continue
            }
        }

        // Hand native calls back in the envelope the parser understands, so
        // `MLXChatClient` has one path to follow either way.
        if !nativeCalls.isEmpty {
            text += nativeCalls.map(Self.envelope(for:)).joined()
        }

        return MLXGenerationResult(
            text: text,
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            finishReason: nativeCalls.isEmpty ? finishReason : "tool_calls"
        )
    }

    // MARK: - Bridging

    /// GrizzyBot's `ChatMessage` list in the shape MLX's chat templates expect.
    /// Assistant tool calls and tool results are preserved so a multi-step
    /// agent turn replays correctly rather than losing the call/result pairing.
    static func chatMessages(from messages: [ChatMessage]) -> [Chat.Message] {
        messages.compactMap { message in
            let content = message.content ?? ""
            switch message.role.lowercased() {
            case "system":
                return .system(content)
            case "assistant":
                let calls = message.toolCalls.map(toolCall(fromLLM:))
                return .assistant(content, toolCalls: calls.isEmpty ? nil : calls)
            case "tool":
                // `Chat.Message.tool(_:id:)` is shadowed by the `tool`
                // property, so build the message directly. The call id is what
                // chat templates use to pair a result with its call.
                let metadata = message.toolCallId.map { Chat.Message.Tool.result(id: $0) }
                return Chat.Message(role: .tool, content: content, tool: metadata)
            default:
                return .user(content)
            }
        }
    }

    /// GrizzyBot's tool definitions as OpenAI-style specs, which is what the
    /// chat templates render.
    static func toolSpecs(from tools: [ChatTool]) -> [ToolSpec]? {
        guard !tools.isEmpty else { return nil }
        return tools.compactMap { tool in
            guard let parameters = tool.function.parameters.any as? [String: any Sendable] else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": parameters,
                ] as [String: any Sendable],
            ] as ToolSpec
        }
    }

    private static func toolCall(from call: MLXLMCommon.ToolCall, index: Int) -> LLMToolCall {
        let object = call.function.arguments.mapValues { $0.anyValue }
        let arguments = (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LLMToolCall(
            id: call.id ?? "mlx_call_\(index + 1)",
            name: call.function.name,
            arguments: arguments
        )
    }

    private static func toolCall(fromLLM call: LLMToolCall) -> MLXLMCommon.ToolCall {
        // Decode straight into MLX's own JSON model rather than through `Any`,
        // so nested objects and arrays in the arguments survive the round trip.
        let arguments = (call.arguments.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: $0) }
            ?? [:]
        return MLXLMCommon.ToolCall(
            function: .init(name: call.name, arguments: arguments),
            id: call.id.isEmpty ? nil : call.id
        )
    }

    private static func envelope(for call: LLMToolCall) -> String {
        let payload: [String: Any] = [
            "name": call.name,
            "arguments": (call.arguments.data(using: .utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return "<tool_call>\(json)</tool_call>"
    }

    /// A length stop must not be reported as a clean finish, or the agent loop
    /// treats a truncated answer as a complete one.
    private static func finishReason(from info: GenerateCompletionInfo) -> String {
        switch info.stopReason {
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .stop: return "stop"
        @unknown default: return "stop"
        }
    }
}
