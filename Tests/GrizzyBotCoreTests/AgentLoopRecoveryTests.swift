import Testing
@testable import GrizzyBotCore

@Suite("AgentLoop recovery")
struct AgentLoopRecoveryTests {
    private let endpoint = ModelEndpoint(provider: "openrouter", model: "test", baseURL: "https://example.com/v1", apiKey: "k")

    private func run(_ client: QueueChatClient, maxSteps: Int = 40, tools: [String] = ["write_file"]) async throws -> AgentLoopResult {
        try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint, botName: "T", prompt: "go",
                tools: AgentToolCatalog.chatTools(enabledIds: tools), maxSteps: maxSteps
            )
        ) { _, _ in AgentToolCallResult(output: "ok") }
    }

    @Test("a reply cut off by the token limit is continued and joined")
    func lengthContinues() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(text: "The first half and", finishReason: "length"),
            ChatCompletionResponse(text: " the second half.", finishReason: "stop"),
        ])
        let result = try await run(client)
        #expect(result.text == "The first half and the second half.")
        #expect(client.requests.last?.messages.last?.content?.contains("hit the output limit") == true)
    }

    @Test("an empty reply after tool calls is asked for again")
    func emptyAfterTools() async throws {
        let call = LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"a\"}")
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [call]),
            ChatCompletionResponse(text: ""),
            ChatCompletionResponse(text: "Wrote the file."),
        ])
        let result = try await run(client)
        #expect(result.text == "Wrote the file.")
        #expect(!result.failed)
    }

    @Test("a persistent empty reply after tools ends with a real message")
    func emptyForever() async throws {
        let call = LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"a\"}")
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [call]),
            ChatCompletionResponse(text: ""), ChatCompletionResponse(text: ""), ChatCompletionResponse(text: ""),
        ])
        let result = try await run(client)
        #expect(result.failed)
        #expect(!result.text.isEmpty)
    }

    @Test("the loop guard stops a run repeating the same call")
    func guardStops() async throws {
        let call = LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"a\"}")
        let client = QueueChatClient((0..<30).map { _ in ChatCompletionResponse(toolCalls: [call]) })
        let result = try await run(client)
        #expect(result.failed)
        #expect(result.failureReason?.hasPrefix("tool loop guard") == true)
        #expect(result.steps < 20)
    }
}

@Suite("ContextSummary")
struct ContextSummaryTests {
    private let endpoint = ModelEndpoint(provider: "openrouter", model: "test", baseURL: "https://example.com/v1", apiKey: "k")

    private func longConversation() -> [ChatMessage] {
        var m: [ChatMessage] = [.system("sys")]
        for i in 0..<10 {
            m.append(.user("question \(i) " + String(repeating: "detail ", count: 80)))
            m.append(.assistant("answer \(i) " + String(repeating: "result ", count: 80)))
        }
        return m
    }

    @Test("old turns are replaced by a model summary and the tail is kept")
    func summarizes() async {
        let client = QueueChatClient([ChatCompletionResponse(text: "Goal: answer ten questions. All answered; nothing open.", inputTokens: 5, outputTokens: 3)])
        var messages = longConversation()
        let tail = Array(messages.suffix(6))
        let usage = await ContextSummary.run(client: client, endpoint: endpoint, messages: &messages, stallMs: 0)
        #expect(usage?.input == 5)
        #expect(messages.count == 8)
        #expect(messages[1].content?.hasPrefix(ContextDigest.prefix) == true)
        #expect(Array(messages.suffix(6)) == tail)
    }

    @Test("a failed or empty summary leaves history untouched")
    func fallsBack() async {
        let client = QueueChatClient([ChatCompletionResponse(text: "")])
        var messages = longConversation()
        let before = messages
        let usage = await ContextSummary.run(client: client, endpoint: endpoint, messages: &messages, stallMs: 0)
        #expect(usage == nil)
        #expect(messages == before)
    }
}
