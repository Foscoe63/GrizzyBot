import Foundation
import GrizzyBotCore
import Testing

@Suite("Transcript integrity")
struct TranscriptIntegrityTests {
    private func turn(_ n: Int) -> [ChatMessage] {
        let call = LLMToolCall(id: "c\(n)", name: "t", arguments: "{}")
        return [
            .user("q\(n)"),
            ChatMessage(role: "assistant", toolCalls: [call]),
            .tool(id: "c\(n)", content: "r\(n)"),
            .assistant("a\(n)"),
        ]
    }

    @Test("a long thread keeps its newest turn and starts on a user message")
    func keepsNewest() {
        var messages: [ChatMessage] = [.system("sys")]
        for n in 0..<70 { messages += turn(n) }
        let kept = ContextCompactor.trimTranscript(messages, limit: 200)
        #expect(kept.count <= 200)
        #expect(kept.first?.role == "user")
        #expect(kept.last?.content == "a69")
    }

    @Test("orphaned tool results are dropped and unanswered calls get a result")
    func repairs() {
        let call = LLMToolCall(id: "x", name: "t", arguments: "{}")
        let messages: [ChatMessage] = [
            .tool(id: "gone", content: "orphan"),
            .user("hi"),
            ChatMessage(role: "assistant", toolCalls: [call]),
            .user("next"),
        ]
        let fixed = ContextCompactor.repairToolPairs(messages)
        #expect(!fixed.contains { $0.toolCallId == "gone" })
        let idx = fixed.firstIndex { $0.role == "assistant" }!
        #expect(fixed[idx + 1].role == "tool" && fixed[idx + 1].toolCallId == "x")
    }

    @Test("a screenshot counts as a fixed size, not its base64 length")
    func imageBudget() {
        let huge = String(repeating: "A", count: 200_000)
        let size = ContextCompactor.encodedSize([ChatMessage(role: "user", content: "s", imageJPEGBase64: huge)])
        #expect(size < 10_000)
    }

    @Test("only the newest screenshots are kept")
    func prunes() {
        var messages = (0..<4).map { ChatMessage(role: "user", content: "s\($0)", imageJPEGBase64: "img\($0)") }
        ContextCompactor.pruneImages(&messages)
        #expect(messages.map { $0.imageJPEGBase64 != nil } == [false, false, true, true])
    }

    @Test("compaction never leaves the tail starting with a tool result")
    func compactionBoundary() {
        var messages: [ChatMessage] = [.system("sys")]
        for n in 0..<12 { messages += turn(n) }
        let big = ChatMessage.user(String(repeating: "x", count: 5_000))
        messages.append(big)
        let result = ContextCompactor.compact(messages, budget: 2_000).messages
        for (i, m) in result.enumerated() where m.role == "tool" {
            #expect(result[i - 1].role == "tool" || result[i - 1].toolCalls.contains { $0.id == m.toolCallId })
        }
    }
}
