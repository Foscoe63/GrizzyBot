import CryptoKit
import Foundation

/// A fingerprint of everything the model is told: the system prompt, the automated recovery
/// prompts, and every built-in tool definition. It is computed from the rendered text, so
/// editing any prompt or tool description changes it without a manual version bump.
public enum PromptVersion {
    /// Short hex hash, stable across launches for identical prompt text.
    public static let current: String = compute()

    public static func compute() -> String {
        var parts: [String] = []
        let endpoint = ModelEndpoint(provider: "openrouter", model: "m", baseURL: "https://example.com/v1", apiKey: "k")
        let tools = AgentToolCatalog.chatTools(enabledIds: AgentToolCatalog.allIds)
        let request = AgentLoopRequest(endpoint: endpoint, botName: "Bot", prompt: "p", tools: tools)
        parts.append(AgentLoop.systemPrompt(for: request, now: Date(timeIntervalSince1970: 0)))
        parts.append(AgentPrompts.continueAfterLength(tail: "tail"))
        parts.append(AgentPrompts.answerAfterTools)
        parts.append(AgentPrompts.noAnswerAfterTools)
        parts.append(AgentPrompts.guardFailing(tool: "t", count: 1))
        parts.append(AgentPrompts.guardSameResult(tool: "t"))
        parts.append(AgentPrompts.guardSimilar(tool: "t", count: 1))
        parts.append(AgentPrompts.guardStopped(reason: "r"))
        parts.append(AgentPrompts.summarize)
        parts.append(AgentPrompts.summaryNoteHeader)
        parts.append(AgentPrompts.memoryFlush)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in tools {
            if let data = try? encoder.encode(tool) { parts.append(String(decoding: data, as: UTF8.self)) }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
