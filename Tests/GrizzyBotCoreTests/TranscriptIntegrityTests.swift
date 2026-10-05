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

@Suite("Anthropic wire")
struct AnthropicWireTests {
    private func request(_ messages: [ChatMessage], model: String = "claude-sonnet-4-5") -> ChatCompletionRequest {
        ChatCompletionRequest(
            endpoint: ModelEndpoint(provider: "anthropic", model: model, baseURL: "https://x", apiKey: "k", style: .anthropic),
            messages: messages,
            tools: [ChatTool(function: ChatToolFunction(name: "t", description: "d", parameters: .object([:])))]
        )
    }

    @Test("images become image blocks and tool results lead their user turn")
    func imagesAndResults() throws {
        let call = LLMToolCall(id: "c1", name: "t", arguments: "{}")
        let body = AnthropicWire.body(for: request([
            .system("sys"),
            .user("go"),
            ChatMessage(role: "assistant", toolCalls: [call]),
            .tool(id: "c1", content: "ok"),
            ChatMessage(role: "user", content: "shot", imageJPEGBase64: "AAAA"),
        ]), stream: false)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 3)
        let last = messages[2]["content"] as! [[String: Any]]
        #expect(last.map { $0["type"] as? String } == ["tool_result", "text", "image"])
        #expect(last.last?["cache_control"] != nil)
    }

    @Test("system prompt and tools are cache breakpoints; max_tokens is raised")
    func caching() {
        let body = AnthropicWire.body(for: request([.system("sys"), .user("hi")]), stream: true)
        #expect(body["stream"] as? Bool == true)
        #expect((body["max_tokens"] as? Int ?? 0) > 4_096)
        let system = body["system"] as! [[String: Any]]
        #expect(system[0]["cache_control"] != nil)
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.last?["cache_control"] != nil)
    }

    @Test("parses a streamed text + tool_use reply")
    func streams() throws {
        var acc = AnthropicStreamAccumulator()
        let lines = [
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hel"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"t"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"1}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var done = false
        for line in lines { done = acc.consume(line: line, onDelta: { _ in }) }
        #expect(done)
        let result = try acc.result()
        #expect(result.text == "hello")
        #expect(result.toolCalls.first?.arguments == #"{"a":1}"#)
        #expect(result.inputTokens == 100)
        #expect(result.outputTokens == 7)
        #expect(result.finishReason == "tool_use")
    }
}
