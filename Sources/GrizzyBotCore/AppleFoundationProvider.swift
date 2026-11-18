import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (macOS 26+ with Apple Intelligence). Free and private, so it suits
/// the small jobs: routing, light replies, summarising. It does not call tools, so it is not offered as a
/// bot's main model.
public enum AppleFoundationProvider {
    public static let id = "apple-foundation"
    public static let name = "Apple Intelligence (on device)"
    public static let modelId = "apple-foundation/on-device"

    public static func isProvider(_ provider: String?) -> Bool {
        provider?.trimmingCharacters(in: .whitespacesAndNewlines) == id
    }

    /// True when this Mac can answer right now.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    public static func catalogEntry() -> CatalogEntry {
        CatalogEntry(
            provider: id,
            providerName: name,
            id: modelId,
            label: "Apple's on-device model — free, private, no tools",
            billing: "Runs on this Mac. Nothing is sent anywhere.",
            auth: .apiKey,
            subscription: false,
            kind: .local,
            defaultBaseUrl: nil,
            supportsBaseUrl: false
        )
    }
}

public struct AppleFoundationClient: ChatCompleting {
    public static let shared = AppleFoundationClient()
    public init() {}

    /// Flattens the chat into one prompt: system text becomes the session instructions.
    static func split(_ messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        let instructions = messages.filter { $0.role == "system" }.compactMap(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != "system" && $0.role != "tool" }
        guard turns.count > 1 else { return (instructions, turns.last?.content ?? "") }
        let prompt = turns.compactMap { m -> String? in
            guard let c = m.content, !c.isEmpty else { return nil }
            return "\(m.role == "assistant" ? "Assistant" : "User"): \(c)"
        }.joined(separator: "\n")
        return (instructions, prompt)
    }

    public func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard AppleFoundationProvider.isAvailable else {
                throw LLMError.http(503, "Apple Intelligence isn't available on this Mac. Turn it on in System Settings, or pick another model.")
            }
            let parts = Self.split(request.messages)
            let session = parts.instructions.isEmpty ? LanguageModelSession() : LanguageModelSession(instructions: parts.instructions)
            let response = try await session.respond(to: parts.prompt)
            return ChatCompletionResponse(
                text: response.content,
                inputTokens: (parts.instructions.count + parts.prompt.count) / 4,
                outputTokens: response.content.count / 4,
                finishReason: "stop"
            )
        }
        #endif
        throw LLMError.http(503, "Apple Intelligence needs macOS 26 or later.")
    }
}
