import Foundation

/// One in-process generation request, already resolved to a bundle on disk.
public struct MLXGenerationRequest: Sendable {
    public var bundleURL: URL
    public var displayName: String
    public var messages: [ChatMessage]
    public var tools: [ChatTool]
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float
    public var repetitionPenalty: Float?

    public init(
        bundleURL: URL,
        displayName: String,
        messages: [ChatMessage],
        tools: [ChatTool] = [],
        maxTokens: Int = 2048,
        temperature: Float = 0.7,
        topP: Float = 0.95,
        repetitionPenalty: Float? = nil
    ) {
        self.bundleURL = bundleURL
        self.displayName = displayName
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
    }
}

public struct MLXGenerationResult: Sendable {
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var finishReason: String?

    public init(
        text: String,
        promptTokens: Int = 0,
        generatedTokens: Int = 0,
        finishReason: String? = nil
    ) {
        self.text = text
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.finishReason = finishReason
    }
}

/// The seam between GrizzyBot's chat plumbing and MLX itself.
///
/// Keeping it a protocol lets everything above it — routing, tool-call
/// recovery, the model picker — be built and unit-tested without linking the
/// MLX runtime, and lets a build for a machine that cannot run MLX substitute
/// a generator that explains why.
public protocol MLXTextGenerating: Sendable {
    func generate(
        _ request: MLXGenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> MLXGenerationResult

    /// Release the loaded model's GPU memory.
    func unload() async
}

/// Used when the MLX runtime is not linked into this build.
public struct MLXUnavailableGenerator: MLXTextGenerating {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func generate(
        _ request: MLXGenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> MLXGenerationResult {
        throw LLMError.http(503, reason)
    }

    public func unload() async {}
}

/// `ChatCompleting` backed by a model running on this Mac's GPU.
///
/// The provider carries no base URL: `ModelEndpoint.model` holds either the
/// absolute path of a discovered bundle or a canonical `org/repo` id, and this
/// client resolves it through `MLXModelLocator` before each request.
public struct MLXChatClient: ChatCompleting {
    public static let shared = MLXChatClient()

    private let generator: any MLXTextGenerating

    public init(generator: (any MLXTextGenerating)? = nil) {
        self.generator = generator ?? MLXRuntime.makeGenerator()
    }

    public func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        try await stream(request, onDelta: { _ in })
    }

    public func stream(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        guard MLXProvider.isSupportedHardware else {
            throw LLMError.http(503, MLXProvider.unsupportedHardwareMessage)
        }
        let selection = request.endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            throw LLMError.notConfigured
        }
        guard let bundle = MLXModelLocator.bundleURL(
            forId: selection,
            customFolders: MLXSettingsStore.customFolders
        ) else {
            throw LLMError.http(
                404,
                "The Local MLX model \"\(selection)\" is no longer on disk. Rescan or download it again in Models."
            )
        }

        let generationRequest = MLXGenerationRequest(
            bundleURL: bundle,
            displayName: selection,
            messages: request.messages,
            tools: request.tools,
            maxTokens: 4096
        )

        // Reasoning and tool envelopes must not reach the transcript, and we
        // only know a chunk is part of one after the tag opens — so deltas are
        // filtered through the same parser the final text goes through.
        let filter = MLXStreamFilter()
        let result = try await generator.generate(generationRequest) { chunk in
            let visible = filter.consume(chunk)
            if !visible.isEmpty { onDelta(visible) }
        }

        let parsed = MLXToolCallParser.parse(result.text)
        return ChatCompletionResponse(
            text: parsed.text,
            toolCalls: parsed.toolCalls,
            inputTokens: result.promptTokens,
            outputTokens: result.generatedTokens,
            finishReason: result.finishReason ?? (parsed.toolCalls.isEmpty ? "stop" : "tool_calls")
        )
    }

    public func unload() async {
        await generator.unload()
    }
}

/// Suppresses reasoning and tool-call envelopes from the live delta stream.
///
/// A streamed chunk can open `<think>` or `<tool_call>` mid-token, so text is
/// held back as soon as it could be the start of a known tag and released once
/// it provably is not. Only the visible prose is forwarded; the authoritative
/// split still happens in `MLXToolCallParser` over the full output.
final class MLXStreamFilter: @unchecked Sendable {
    private static let openers = [
        "<think>", "<thinking>", "<reasoning>", "<tool_call>", "[TOOL_CALLS]", "```",
    ]
    private static let closers: [String: String] = [
        "<think>": "</think>",
        "<thinking>": "</thinking>",
        "<reasoning>": "</reasoning>",
        "<tool_call>": "</tool_call>",
    ]

    private let lock = NSLock()
    private var pending = ""
    private var suppressingUntil: String?

    func consume(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        pending += chunk
        var output = ""

        while !pending.isEmpty {
            if let closer = suppressingUntil {
                guard let end = pending.range(of: closer) else {
                    // Keep only enough tail to recognize the closing tag.
                    pending = String(pending.suffix(closer.count))
                    return output
                }
                pending.removeSubrange(pending.startIndex..<end.upperBound)
                suppressingUntil = nil
                continue
            }

            if let (opener, range) = firstOpener(in: pending) {
                output += String(pending[pending.startIndex..<range.lowerBound])
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                // `[TOOL_CALLS]` and a bare fence have no closing tag we can
                // rely on; from there the rest of the turn is machinery.
                suppressingUntil = Self.closers[opener] ?? "\u{0}"
                continue
            }

            // Hold back a possible partial opener at the tail.
            let keep = longestPartialOpenerSuffix(of: pending)
            let cut = pending.index(pending.endIndex, offsetBy: -keep)
            output += String(pending[pending.startIndex..<cut])
            pending = String(pending[cut...])
            break
        }
        return output
    }

    private func firstOpener(in text: String) -> (String, Range<String.Index>)? {
        var best: (String, Range<String.Index>)?
        for opener in Self.openers {
            guard let range = text.range(of: opener) else { continue }
            if best == nil || range.lowerBound < best!.1.lowerBound {
                best = (opener, range)
            }
        }
        return best
    }

    private func longestPartialOpenerSuffix(of text: String) -> Int {
        var longest = 0
        for opener in Self.openers {
            var length = min(opener.count - 1, text.count)
            while length > 0 {
                if text.hasSuffix(String(opener.prefix(length))) {
                    longest = max(longest, length)
                    break
                }
                length -= 1
            }
        }
        return longest
    }
}
