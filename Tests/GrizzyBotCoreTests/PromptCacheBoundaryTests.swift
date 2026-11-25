import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Prompt cache boundary")
struct PromptCacheBoundaryTests {
    private func loopRequest(memory: String) -> AgentLoopRequest {
        AgentLoopRequest(
            endpoint: ModelEndpoint(provider: "anthropic", model: "claude-sonnet-4-5", baseURL: "https://x", apiKey: "k", style: .anthropic),
            botName: "Scout", memory: memory, prompt: "hi", tools: []
        )
    }

    private func wire(_ message: ChatMessage) -> ChatCompletionRequest {
        ChatCompletionRequest(
            endpoint: ModelEndpoint(provider: "anthropic", model: "claude-sonnet-4-5", baseURL: "https://x", apiKey: "k", style: .anthropic),
            messages: [message, .user("hi")]
        )
    }

    private func systemBlocks(_ body: [String: Any]) -> [[String: Any]] { body["system"] as? [[String: Any]] ?? [] }

    @Test("memory and the date sit after the cache breakpoint")
    func volatileAfterBreakpoint() {
        let parts = AgentLoop.systemPromptParts(for: loopRequest(memory: "likes tea"))
        #expect(parts.volatile.contains("likes tea"))
        #expect(parts.volatile.contains("Today is"))
        #expect(!parts.stable.contains("likes tea"))
        #expect(!parts.stable.contains("Today is"))
    }

    @Test("the whole prompt is still one string for other providers")
    func joinedPrompt() {
        let request = loopRequest(memory: "likes tea")
        let parts = AgentLoop.systemPromptParts(for: request)
        let whole = AgentLoop.systemPrompt(for: request)
        #expect(whole.contains(parts.stable))
        #expect(whole.contains("likes tea"))
    }

    @Test("Anthropic caches only the stable block, and a memory change leaves it identical")
    func cachedBlockUnchangedByMemory() throws {
        let a = systemBlocks(AnthropicWire.body(for: wire(AgentLoop.systemMessage(for: loopRequest(memory: "one"))), stream: true))
        let b = systemBlocks(AnthropicWire.body(for: wire(AgentLoop.systemMessage(for: loopRequest(memory: "two"))), stream: true))
        #expect(a.count == 2)
        #expect(a[0]["cache_control"] != nil)
        #expect(a[1]["cache_control"] == nil)
        #expect((a[1]["text"] as? String)?.contains("one") == true)
        #expect(a[0]["text"] as? String == b[0]["text"] as? String)
    }

    @Test("a system message with no boundary is one cached block, as before")
    func noBoundary() {
        let blocks = systemBlocks(AnthropicWire.body(for: wire(.system("sys")), stream: true))
        #expect(blocks.count == 1)
        #expect(blocks[0]["cache_control"] != nil)
    }
}
