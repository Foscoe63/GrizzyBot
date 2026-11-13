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

    /// KV cache from the previous turn plus the prompt tokens it covers. The
    /// next prompt usually starts with the same system prompt and history, so
    /// only the new tail needs prefilling. Cleared whenever the model changes.
    private var promptCache: PromptCache?

    /// MLX's recycled-buffer cache is on top of the weights, so a generous
    /// limit let a 39 GB model grow to ~75 GB. Keep it small; the cache only
    /// speeds up allocator reuse.
    private static let cacheLimitBytes = 1 << 30

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
            promptCache = nil
            MLX.Memory.clearCache()
        }

        MLX.Memory.cacheLimit = Self.cacheLimitBytes

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
        promptCache = nil
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
        // Release scratch buffers (prefill/KV growth) once the turn ends.
        defer { MLX.Memory.clearCache() }
        let reusable = promptCache
        promptCache = nil  // re-stored below only if the turn finishes cleanly
        let started = try await container.perform(
            nonSendable: SendableInput(prepared, reusable)
        ) { context, box in
            try Self.startGeneration(box: box, parameters: parameters, context: context)
        }
        let stream = started.stream
        let activeCache = started.cache

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

        // Keep the prompt's cache for the next turn: trim off what this turn
        // generated so the cache covers exactly the prompt tokens.
        if !Task.isCancelled, activeCache.trimmable {
            let extra = (activeCache.layers.first?.offset ?? 0) - activeCache.promptTokens.count
            if extra >= 0, activeCache.layers.allSatisfy({ $0.trim(extra) == extra }) {
                promptCache = activeCache
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

    // MARK: - Prompt cache

    /// Layers plus the prompt tokens they hold. A reference type because the
    /// generation task mutates the layers in place.
    final class PromptCache: @unchecked Sendable {
        let layers: [KVCache]
        var promptTokens: [Int]
        let trimmable: Bool
        init(layers: [KVCache], promptTokens: [Int]) {
            self.layers = layers
            self.promptTokens = promptTokens
            self.trimmable = layers.allSatisfy { $0.isTrimmable }
        }
    }

    struct SendableInput {
        let input: LMInput
        let reusable: PromptCache?
        init(_ input: LMInput, _ reusable: PromptCache?) {
            self.input = input
            self.reusable = reusable
        }
    }

    struct Started: @unchecked Sendable {
        let stream: AsyncStream<Generation>
        let cache: PromptCache
    }

    /// Start generation, prefilling only the part of the prompt the cached
    /// layers don't already cover. Text-only prompts on trimmable caches get
    /// reuse; anything else (images, hybrid-state layers) prefills in full.
    static func startGeneration(
        box: SendableInput,
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> Started {
        let input = box.input
        let tokens = input.text.tokens.reshaped(-1).asArray(Int.self)
        let textOnly = input.image == nil && input.video == nil && input.audio == nil

        var cache = PromptCache(
            layers: context.model.newCache(parameters: parameters), promptTokens: tokens)
        var feed = input

        if textOnly, let old = box.reusable, old.trimmable {
            var shared = 0
            let limit = min(old.promptTokens.count, tokens.count)
            while shared < limit, old.promptTokens[shared] == tokens[shared] { shared += 1 }
            // Always feed at least the last token so the model has logits to sample from.
            shared = min(shared, tokens.count - 1)
            let drop = (old.layers.first?.offset ?? 0) - shared
            if shared > 0, drop >= 0, old.layers.allSatisfy({ $0.trim(drop) == drop }) {
                cache = PromptCache(layers: old.layers, promptTokens: tokens)
                feed = LMInput(tokens: MLXArray(Array(tokens[shared...])))
            }
        }

        let stream = try MLXLMCommon.generate(
            input: feed, cache: cache.layers, parameters: parameters, context: context)
        return Started(stream: stream, cache: cache)
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
            guard let parameters = Self.strippingNulls(tool.function.parameters.any)
                as? [String: any Sendable] else {
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

    /// The chat template is rendered by Jinja, which cannot convert `NSNull`.
    /// MCP tool schemas routinely carry explicit nulls (`"default": null`), so
    /// drop them before the schema reaches the template.
    static func strippingNulls(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { !($0.value is NSNull) }.mapValues(strippingNulls)
        case let array as [Any]:
            return array.filter { !($0 is NSNull) }.map(strippingNulls)
        default:
            return value
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
