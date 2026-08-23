import Foundation

/// Live prompt estimates and billed token rollups for the composer.
public enum TokenAccounting: Sendable {
    /// Rough OpenAI-style estimate: about four UTF-8 bytes per token.
    public static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, (trimmed.utf8.count + 3) / 4)
    }

    /// Composer box while typing; last billed first-call prompt after send.
    public static func displayedPrompt(draft: String, lastBilledPrompt: Int) -> Int {
        let live = estimate(draft)
        return live > 0 ? live : max(0, lastBilledPrompt)
    }

    public static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

public struct ChatTokenStats: Equatable, Sendable {
    public var lastPromptTokens: Int
    public var sentTokens: Int
    public var receivedTokens: Int

    public init(lastPromptTokens: Int = 0, sentTokens: Int = 0, receivedTokens: Int = 0) {
        self.lastPromptTokens = lastPromptTokens
        self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens
    }
}
