import Foundation
import GrizzyBotCore
import Testing

@Suite("LLMClient")
struct LLMClientTests {
    @Test("parses OpenAI tool calls and usage")
    func parseOpenAI() throws {
        let json = """
        {
          "choices": [{
            "finish_reason": "tool_calls",
            "message": {
              "role": "assistant",
              "content": null,
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {
                  "name": "write_file",
                  "arguments": "{\\"path\\":\\"notes/a.txt\\",\\"content\\":\\"hi\\"}"
                }
              }]
            }
          }],
          "usage": { "prompt_tokens": 11, "completion_tokens": 7 }
        }
        """.data(using: .utf8)!
        let response = try OpenAIChatClient.parseOpenAI(json)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "write_file")
        #expect(response.toolCalls[0].arguments.contains("notes/a.txt"))
        #expect(response.inputTokens == 11)
        #expect(response.outputTokens == 7)
    }

    @Test("parses Anthropic text + tool_use")
    func parseAnthropic() throws {
        let json = """
        {
          "stop_reason": "tool_use",
          "content": [
            { "type": "text", "text": "writing" },
            {
              "type": "tool_use",
              "id": "toolu_1",
              "name": "web_search",
              "input": { "query": "otters" }
            }
          ],
          "usage": { "input_tokens": 4, "output_tokens": 9 }
        }
        """.data(using: .utf8)!
        let response = try OpenAIChatClient.parseAnthropic(json)
        #expect(response.text == "writing")
        #expect(response.toolCalls.first?.name == "web_search")
        #expect(response.toolCalls.first?.arguments.contains("otters") == true)
        #expect(response.inputTokens == 4)
    }

    @Test("routing requires a key for cloud providers")
    func routing() {
        #expect(throws: LLMError.notConfigured) {
            try LLMRouting.endpoint(provider: "openrouter", modelId: "x", apiKey: nil, baseUrl: nil)
        }
        #expect(LLMRouting.canRun(provider: "ollama", apiKey: nil, baseUrl: nil, injectedClient: false))
        #expect(!LLMRouting.canRun(provider: "openrouter", apiKey: nil, baseUrl: nil, injectedClient: false))
        let local = try? LLMRouting.endpoint(provider: "ollama", modelId: "llama3", apiKey: nil, baseUrl: nil)
        #expect(local?.baseURL.contains("11434") == true)
        #expect(local?.style == .openAI)
        let anthropic = try? LLMRouting.endpoint(
            provider: "anthropic",
            modelId: "claude-sonnet-4-5",
            apiKey: "sk-ant",
            baseUrl: nil
        )
        #expect(anthropic?.style == .anthropic)
    }
}

final class QueueChatClient: ChatCompleting, @unchecked Sendable {
    var queue: [ChatCompletionResponse]
    var requests: [ChatCompletionRequest] = []
    var lastToolName: String = ""

    init(_ queue: [ChatCompletionResponse]) {
        self.queue = queue
    }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        requests.append(request)
        if queue.isEmpty {
            return ChatCompletionResponse(text: "done.")
        }
        return queue.removeFirst()
    }
}

@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("returns assistant text when there are no tool calls")
    func textOnly() async throws {
        let client = QueueChatClient([ChatCompletionResponse(text: "hello from the model")])
        let endpoint = ModelEndpoint(
            provider: "openrouter",
            model: "test",
            baseURL: "https://example.com/v1",
            apiKey: "k"
        )
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "Scout",
                instructions: "Be brief.",
                prompt: "hi",
                tools: []
            )
        ) { _, _ in
            AgentToolCallResult(output: "unused")
        }
        #expect(result.text == "hello from the model")
        #expect(result.blocks.isEmpty)
        #expect(client.requests.first?.messages.contains(where: { $0.role == "system" && ($0.content ?? "").contains("Scout") }) == true)
        #expect(client.requests.first?.messages.contains(where: { $0.role == "system" && ($0.content ?? "").contains("Be brief.") }) == true)
        #expect(client.requests.first?.messages.contains(where: {
            $0.role == "system" && ($0.content ?? "").contains("Box.com") && ($0.content ?? "").contains("Composio Connect")
        }) == true)
    }

    @Test("drops web tools after repeated empty searches")
    func stallsWebRetries() async throws {
        let search = LLMToolCall(id: "1", name: "web_search", arguments: "{\"query\":\"box key\"}")
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [search]),
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "2", name: "web_search", arguments: "{\"query\":\"box key 2\"}")]),
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "3", name: "web_search", arguments: "{\"query\":\"box key 3\"}")]),
            ChatCompletionResponse(text: "I could not reach the web. The Box.com key is a local Settings field."),
        ])
        let endpoint = ModelEndpoint(
            provider: "openrouter",
            model: "test",
            baseURL: "https://example.com/v1",
            apiKey: "k"
        )
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "Researcher",
                prompt: "What is the Box key in the Composio Connect setup",
                tools: AgentToolCatalog.chatTools(enabledIds: ["web_search"]),
                maxSteps: 8
            )
        ) { _, _ in
            AgentToolCallResult(output: "No results for box key.")
        }
        #expect(client.requests.count >= 4)
        let lastTools = client.requests.last?.tools.map(\.function.name) ?? []
        #expect(!lastTools.contains("web_search"))
        #expect(!lastTools.contains("web_fetch"))
        #expect(result.text.contains("Box.com") || result.text.contains("could not"))
    }

    @Test("executes tool calls then returns the follow-up text")
    func toolThenText() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"a.txt\"}")]
            ),
            ChatCompletionResponse(text: "wrote it."),
        ])
        let endpoint = ModelEndpoint(
            provider: "openrouter",
            model: "test",
            baseURL: "https://example.com/v1",
            apiKey: "k"
        )
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "Scout",
                prompt: "write a file",
                tools: AgentToolCatalog.chatTools(enabledIds: ["write_file"])
            )
        ) { name, args in
            client.lastToolName = "\(name) \(args)"
            return AgentToolCallResult(
                output: "ok",
                blocks: [.card(lines: [CardLine(k: "wrote", v: "a.txt")])]
            )
        }
        #expect(result.text == "wrote it.")
        #expect(client.lastToolName.contains("write_file"))
        #expect(result.blocks.count == 1)
        #expect(client.requests.count == 2)
        #expect(client.requests[1].messages.contains(where: { $0.role == "tool" }))
    }

    @Test("strips leaked think tags from visible text")
    func stripThink() {
        let raw = "<think>secret chain</think>\n\nHello from the model"
        #expect(StreamText.visible(raw) == "Hello from the model")
        #expect(StreamText.visible("<think>still thinking") == "")
    }
}

@Suite("Agent chat tools")
struct AgentChatToolTests {
    @Test("exposes builtins and MCP wrappers for enabled tools")
    func schemas() {
        let server = McpServer(id: "srv1", name: "fs", command: "mcp")
        let tools = AgentToolCatalog.chatTools(
            enabledIds: ["write_file", "web_search", server.toolId],
            mcpServers: [server]
        )
        let names = Set(tools.map(\.function.name))
        #expect(names.contains("write_file"))
        #expect(names.contains("web_fetch"))
        #expect(names.contains("mcp_call"))
        #expect(!names.contains("shell"))
        #expect(!names.contains("spawn_bot"))
    }
}

@Suite("Context compaction")
struct CompactionTests {
    @Test("shrinks oversized tool payloads")
    func compact() {
        var messages = [ChatMessage.system("sys")]
        for i in 0..<20 {
            messages.append(.tool(id: "\(i)", content: String(repeating: "x", count: 8000)))
        }
        let packed = ContextCompactor.compact(messages, budget: 20_000)
        #expect(packed.compacted)
        #expect(ContextCompactor.encodedSize(packed.messages) < ContextCompactor.encodedSize(messages))
    }

    @Test("compacts recent tool dumps so a follow-up request still fits")
    func compactRecent() {
        var messages = [ChatMessage.system("sys")]
        for i in 0..<10 {
            messages.append(.tool(id: "\(i)", content: String(repeating: "x", count: 8_000)))
        }
        let packed = ContextCompactor.compact(messages, budget: 20_000)
        #expect(packed.compacted)
        #expect(ContextCompactor.encodedSize(packed.messages) <= 20_000)
    }
}

@Suite("Destinations")
struct DestinationTests {
    @Test("appends jsonl records")
    func jsonl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString)", isDirectory: true)
        let store = DestinationStore(root: root)
        try store.append(DestinationRecord(slug: "github", title: "T", body: "B"))
        let listed = store.list(slug: "github")
        #expect(listed.count == 1)
        #expect(listed[0].title == "T")
    }
}
