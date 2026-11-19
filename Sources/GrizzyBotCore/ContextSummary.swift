import Foundation

/// Model-written summary of the span compaction would otherwise drop. Runs before the
/// mechanical digest; any failure returns nil and the caller falls back to truncation.
enum ContextSummary {
    static let maxPerRun = 3
    static let maxTranscriptChars = 24_000
    static let maxSummaryChars = 3_500

    static let instruction = AgentPrompts.summarize

    /// Index where the kept tail starts, or nil when there is nothing worth summarizing.
    /// Mirrors `ContextCompactor.compact`'s split so the two agree on what is "old".
    static func tailStart(_ messages: [ChatMessage]) -> Int? {
        guard messages.count > 8 else { return nil }
        var start = messages.count - 6
        while start > 1, messages[start].role == "tool" { start -= 1 }
        return start > 1 ? start : nil
    }

    static func transcript(_ dropped: [ChatMessage]) -> String {
        var lines: [String] = []
        for m in dropped where !PinnedFacts.isPinMessage(m) {
            let body = (m.content ?? "").replacingOccurrences(of: "\n", with: " ")
            switch m.role {
            case "assistant":
                for c in m.toolCalls { lines.append("assistant called \(c.name)(\(clip(c.arguments, 300)))") }
                if !body.isEmpty { lines.append("assistant: " + clip(body, 1_200)) }
            case "tool":
                lines.append("tool result: " + clip(body, 700))
            default:
                lines.append("\(m.role): " + clip(body, 1_500))
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxTranscriptChars {
            text = String(text.prefix(maxTranscriptChars / 3)) + "\n…\n" + String(text.suffix(maxTranscriptChars * 2 / 3))
        }
        return text
    }

    static func note(_ summary: String) -> ChatMessage {
        .user("\(ContextDigest.prefix) \(AgentPrompts.summaryNoteHeader)\n" + summary)
    }

    /// Replaces messages[1..<tailStart] with one summary note. Returns tokens spent.
    static func run(
        client: any ChatCompleting,
        endpoint: ModelEndpoint,
        messages: inout [ChatMessage],
        stallMs: Int
    ) async -> (input: Int, output: Int)? {
        guard let start = tailStart(messages) else { return nil }
        let dropped = Array(messages[1..<start])
        let body = transcript(dropped)
        guard body.count > 400 else { return nil }
        let ask: [ChatMessage] = [.system(instruction), .user("Session to summarize:\n\n" + body)]
        let request = ChatCompletionRequest(endpoint: endpoint, messages: ask, tools: [], stallMs: stallMs)
        guard let response = try? await client.complete(request) else { return nil }
        let summary = StreamText.visible(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.count >= 40 else { return nil }
        let clipped = summary.count > maxSummaryChars ? String(summary.prefix(maxSummaryChars)) + "…" : summary
        messages = [messages[0], note(clipped)] + Array(messages[start...])
        messages = ContextCompactor.repairToolPairs(messages)
        return (response.inputTokens, response.outputTokens)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}
