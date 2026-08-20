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
        let compatible = try? LLMRouting.endpoint(
            provider: "openai-compatible",
            modelId: "llama3",
            apiKey: nil,
            baseUrl: "https://llm.example.com"
        )
        #expect(compatible?.baseURL == "https://llm.example.com/v1")
        #expect(compatible?.apiKey == "local")
        #expect(LLMRouting.canRun(
            provider: "openai-compatible",
            apiKey: nil,
            baseUrl: "https://llm.example.com/v1",
            injectedClient: false
        ))
        #expect(!LLMRouting.canRun(
            provider: "openai-compatible",
            apiKey: nil,
            baseUrl: nil,
            injectedClient: false
        ))
    }

    @Test("tool messages never carry image parts")
    func toolMessageNoImages() {
        var message = ChatMessage.tool(id: "c1", content: "captured 1024×640")
        message.imageJPEGBase64 = "AAAA"
        let wire = OpenAIChatClient.wireMessage(message, includeImages: true)
        #expect(wire["role"] as? String == "tool")
        #expect(wire["content"] as? String == "captured 1024×640")
        #expect(wire["tool_call_id"] as? String == "c1")
    }

    @Test("local payloads drop image parts that LM Studio rejects")
    func localDropsImages() {
        var message = ChatMessage.user("see this")
        message.imageJPEGBase64 = "AAAA"
        let wire = OpenAIChatClient.wireMessage(message, includeImages: false)
        #expect(wire["content"] as? String == "see this")
        #expect(!LLMRouting.supportsVisionImages(provider: "lmstudio", model: "qwen3-coder-next-mlx"))
        #expect(LLMRouting.supportsVisionImages(provider: "openai", model: "gpt-4o"))
        #expect(!LLMRouting.supportsVisionImages(provider: "deepseek", model: "deepseek-chat"))
        #expect(!LLMRouting.supportsVisionImages(provider: "groq", model: "llama-3.3-70b-versatile"))
        #expect(LLMRouting.supportsVisionImages(provider: "openai", model: "gpt-4o-mini"))
    }

    @Test("vision user messages keep image parts")
    func visionKeepsImages() {
        var message = ChatMessage.user("see this")
        message.imageJPEGBase64 = "AAAA"
        let wire = OpenAIChatClient.wireMessage(message, includeImages: true)
        let parts = wire["content"] as? [[String: Any]]
        #expect(parts?.contains(where: { $0["type"] as? String == "image_url" }) == true)
    }

    @Test("offline URLError for a LAN host is not reported as a generic internet outage")
    func localOfflineMessage() {
        let url = URL(string: "http://192.168.1.40:11434/v1/chat/completions")!
        let error = URLError(.notConnectedToInternet)
        let mapped = LLMError.transport(error, url: url)
        guard case .http(-1, let body) = mapped else {
            Issue.record("expected http(-1)")
            return
        }
        #expect(body.contains("Local Network"))
        #expect(!body.contains("The Internet connection appears to be offline"))
        #expect(ModelTransport.isLocalNetwork(url))
        #expect(!ModelTransport.isLocalNetwork(URL(string: "https://openrouter.ai/api/v1/chat/completions")!))
    }

    @Test("retries 5xx and transport failures")
    func retryPolicy() {
        #expect(ModelRequestRetry.isRetryable(LLMError.http(500, "Internal Server Error")))
        #expect(ModelRequestRetry.isRetryable(LLMError.http(429, "rate limit")))
        #expect(ModelRequestRetry.isRetryable(LLMError.http(-1, "timed out")))
        #expect(!ModelRequestRetry.isRetryable(LLMError.http(401, "unauthorized")))
        #expect(!ModelRequestRetry.isRetryable(LLMError.notConfigured))
        #expect(ModelRequestRetry.shouldCompactOnRetry(LLMError.http(502, "bad gateway")))
        #expect(!ModelRequestRetry.shouldCompactOnRetry(LLMError.http(-1, "offline")))
    }
}

final class QueueChatClient: ChatCompleting, @unchecked Sendable {
    var queue: [Result<ChatCompletionResponse, Error>]
    var requests: [ChatCompletionRequest] = []
    var lastToolName: String = ""

    init(_ queue: [ChatCompletionResponse]) {
        self.queue = queue.map { .success($0) }
    }

    init(results: [Result<ChatCompletionResponse, Error>]) {
        self.queue = results
    }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        requests.append(request)
        if queue.isEmpty {
            return ChatCompletionResponse(text: "done.")
        }
        switch queue.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

final class FailAfterToolsClient: ChatCompleting, @unchecked Sendable {
    let first: ChatCompletionResponse
    var calls = 0

    init(first: ChatCompletionResponse) {
        self.first = first
    }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        calls += 1
        if calls == 1 { return first }
        throw LLMError.http(500, "Internal Server Error")
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

    @Test("system prompt includes UTC today and yesterday")
    func utcDatesInPrompt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 19))!
        #expect(AgentLoop.utcDateLine(now: now).contains("2026-08-19"))
        #expect(AgentLoop.utcDateLine(now: now).contains("2026-08-18"))
        let prompt = AgentLoop.systemPrompt(
            for: AgentLoopRequest(
                endpoint: ModelEndpoint(provider: "x", model: "y", baseURL: "https://x", apiKey: "k"),
                botName: "Scout",
                prompt: "hi",
                tools: []
            ),
            now: now
        )
        #expect(prompt.contains("Today is 2026-08-19 (UTC)"))
        #expect(prompt.contains("Yesterday UTC is 2026-08-18"))
        #expect(prompt.contains("obsidian_put_file"))
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

    @Test("retries transient model errors then succeeds")
    func retriesModelErrors() async throws {
        let client = QueueChatClient(results: [
            .failure(LLMError.http(500, "Internal Server Error")),
            .failure(LLMError.http(502, "Bad Gateway")),
            .success(ChatCompletionResponse(text: "recovered")),
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
                prompt: "summarize",
                tools: []
            )
        ) { _, _ in
            AgentToolCallResult(output: "unused")
        }
        #expect(result.text == "recovered")
        #expect(client.requests.count == 3)
    }

    @Test("returns partial tool progress when the model fails after tools ran")
    func partialOnModelFailure() async throws {
        let search = LLMToolCall(id: "1", name: "web_search", arguments: "{\"query\":\"swift agents\"}")
        let client = FailAfterToolsClient(first: ChatCompletionResponse(toolCalls: [search]))
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
                prompt: "find repos",
                tools: AgentToolCatalog.chatTools(enabledIds: ["web_search"]),
                maxSteps: 4
            )
        ) { _, _ in
            AgentToolCallResult(
                output: "https://github.com/example/repo",
                blocks: [.card(lines: [CardLine(k: "found", v: "repo")])]
            )
        }
        #expect(result.text.contains("stopped responding"))
        #expect(result.blocks.contains(where: {
            if case .card = $0 { return true }
            return false
        }))
        #expect(client.calls >= ModelRequestRetry.maxAttempts)
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
        let call = tools.first { $0.function.name == "mcp_call" }
        #expect(call?.function.description.contains("filepath") == true || call?.function.description.contains("arguments") == true)
    }

    @Test("Toolport MCP wrappers mention the lazy gateway")
    func toolportSchemas() {
        let server = McpServer(id: "tp", name: "Toolport", command: "toolport-gateway")
        let tools = AgentToolCatalog.chatTools(
            enabledIds: [server.toolId],
            mcpServers: [server]
        )
        let call = tools.first { $0.function.name == "mcp_call" }
        #expect(call?.function.description.contains("github__search_repositories") == true)
        #expect(call?.function.description.contains("never id") == true)
        let list = tools.first { $0.function.name == "mcp_list_tools" }
        #expect(list?.function.description.contains("meta-tools") == true)
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

    @Test("compacted tool-call arguments stay valid JSON")
    func compactToolArgumentsStayJSON() throws {
        let giant = String(repeating: "hello world ", count: 400)
        let arguments = "{\"path\":\"notes/a.md\",\"content\":\"\(giant)\"}"
        let compacted = ContextCompactor.compactToolArguments(arguments, limit: 800)
        #expect(ContextCompactor.isValidJSON(compacted))
        let data = try #require(compacted.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["path"] as? String == "notes/a.md")
        let content = try #require(object["content"] as? String)
        #expect(content.count < giant.count)
    }

    @Test("invalid tool-call arguments are wrapped as JSON")
    func sanitizeBrokenToolArguments() {
        let broken = "{\"content\":\"hello\n…[summarized 5383 chars]…\nworld\""
        let fixed = ContextCompactor.ensureValidJSONArguments(broken)
        #expect(ContextCompactor.isValidJSON(fixed))
        let wire = OpenAIChatClient.wireMessage(
            ChatMessage(
                role: "assistant",
                content: "writing",
                toolCalls: [LLMToolCall(id: "1", name: "write_file", arguments: broken)]
            )
        )
        let calls = wire["tool_calls"] as? [[String: Any]]
        let function = calls?.first?["function"] as? [String: Any]
        let sent = function?["arguments"] as? String ?? ""
        #expect(ContextCompactor.isValidJSON(sent))
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
