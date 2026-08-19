import Foundation
import GrizzyBotCore
import Testing

// MARK: - Eval harness

struct AgentEvalSpec: Sendable {
    let name: String
    let prompt: String
    let responses: [ChatCompletionResponse]
    let expectedTools: [String]
    let expectedTextContains: [String]
    let exactToolOrder: Bool

    init(
        name: String,
        prompt: String,
        responses: [ChatCompletionResponse],
        expectedTools: [String],
        expectedTextContains: [String] = [],
        exactToolOrder: Bool = true
    ) {
        self.name = name
        self.prompt = prompt
        self.responses = responses
        self.expectedTools = expectedTools
        self.expectedTextContains = expectedTextContains
        self.exactToolOrder = exactToolOrder
    }
}

final class ToolCallRecorder: @unchecked Sendable {
    private(set) var tools: [String] = []
    private(set) var toolArguments: [String] = []

    func record(name: String, arguments: String) -> AgentToolCallResult {
        tools.append(name)
        toolArguments.append(arguments)
        return AgentToolCallResult(output: "ok:\(name)")
    }

    func assertExpected(_ expected: [String], exactOrder: Bool, file: SourceLocation = #_sourceLocation) {
        if exactOrder {
            #expect(tools == expected, "Expected tools \(expected), got \(tools)", sourceLocation: file)
        } else {
            #expect(Set(tools) == Set(expected), "Expected tool set \(expected), got \(tools)", sourceLocation: file)
        }
    }
}

enum AgentEvalRunner {
    static func testEndpoint() -> ModelEndpoint {
        ModelEndpoint(provider: "openrouter", model: "eval-model", baseURL: "https://example.com/v1", apiKey: "k")
    }

    static func runLoop(
        spec: AgentEvalSpec,
        file: SourceLocation = #_sourceLocation
    ) async throws -> (AgentLoopResult, ToolCallRecorder) {
        let client = QueueChatClient(spec.responses)
        let recorder = ToolCallRecorder()
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: testEndpoint(),
                botName: "EvalBot",
                prompt: spec.prompt,
                tools: AgentToolCatalog.chatTools(enabledIds: AgentToolCatalog.allIds)
            )
        ) { name, args in
            recorder.record(name: name, arguments: args)
        }
        recorder.assertExpected(spec.expectedTools, exactOrder: spec.exactToolOrder, file: file)
        for needle in spec.expectedTextContains {
            #expect(result.text.contains(needle), "Expected '\(needle)' in \(result.text)", sourceLocation: file)
        }
        return (result, recorder)
    }

    @MainActor
    static func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotEval-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return store
    }
}

// MARK: - Fixed-prompt agent loop evals (CI gate)

@Suite("Agent eval CI")
struct AgentEvalCITests {
    @Test("CI-01 write_file then confirm")
    func writeFile() async throws {
        let spec = AgentEvalSpec(
            name: "write_file",
            prompt: "Create notes/hello.txt with content hello world",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"notes/hello.txt\",\"content\":\"hello world\"}"),
                ]),
                ChatCompletionResponse(text: "Created notes/hello.txt"),
            ],
            expectedTools: ["write_file"],
            expectedTextContains: ["hello"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-02 parallel web_search and web_fetch")
    func searchAndFetch() async throws {
        let spec = AgentEvalSpec(
            name: "search_fetch",
            prompt: "Research sea otters online",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "web_search", arguments: "{\"query\":\"sea otters\"}"),
                    LLMToolCall(id: "2", name: "web_fetch", arguments: "{\"url\":\"https://example.com/otters\"}"),
                ]),
                ChatCompletionResponse(text: "Sea otters are marine mammals."),
            ],
            expectedTools: ["web_search", "web_fetch"],
            expectedTextContains: ["otter"],
            exactToolOrder: false
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-03 shell pauses for approval")
    func shellPause() async throws {
        let spec = AgentEvalSpec(
            name: "shell_pause",
            prompt: "Run ls in the bot home",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "shell", arguments: "{\"command\":\"ls -la\"}"),
                ]),
            ],
            expectedTools: ["shell"]
        )
        let client = QueueChatClient(spec.responses)
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: AgentEvalRunner.testEndpoint(), botName: "EvalBot", prompt: spec.prompt, tools: [])
        ) { _, _ in
            AgentToolCallResult(
                output: "Needs approval",
                blocks: [.approval(tool: "shell.exec", detail: "ls -la", status: .pending)],
                pause: .approval(tool: "shell.exec", detail: "ls -la", arguments: "{\"command\":\"ls -la\"}")
            )
        }
        #expect(result.pause != nil)
    }

    @Test("CI-04 read_file after model chooses it")
    func readFile() async throws {
        let spec = AgentEvalSpec(
            name: "read_file",
            prompt: "Read notes/brief.md",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "read_file", arguments: "{\"path\":\"notes/brief.md\"}"),
                ]),
                ChatCompletionResponse(text: "The brief mentions quarterly goals."),
            ],
            expectedTools: ["read_file"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-05 list_files")
    func listFiles() async throws {
        let spec = AgentEvalSpec(
            name: "list_files",
            prompt: "List everything in notes/",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "list_files", arguments: "{\"directory\":\"notes\"}"),
                ]),
                ChatCompletionResponse(text: "Found brief.md and todo.txt"),
            ],
            expectedTools: ["list_files"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-06 remember durable fact")
    func remember() async throws {
        let spec = AgentEvalSpec(
            name: "remember",
            prompt: "Remember that my timezone is US/Pacific",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "remember", arguments: "{\"content\":\"User timezone is US/Pacific\",\"scope\":\"bot\"}"),
                ]),
                ChatCompletionResponse(text: "Saved your timezone."),
            ],
            expectedTools: ["remember"],
            expectedTextContains: ["timezone"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-07 edit_file patch")
    func editFile() async throws {
        let spec = AgentEvalSpec(
            name: "edit_file",
            prompt: "Change the title in notes/draft.md",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "edit_file", arguments: "{\"path\":\"notes/draft.md\",\"old_text\":\"Draft\",\"new_text\":\"Final\"}"),
                ]),
                ChatCompletionResponse(text: "Updated the title."),
            ],
            expectedTools: ["edit_file"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-08 plugin_call routes to connector")
    func pluginCall() async throws {
        let spec = AgentEvalSpec(
            name: "plugin_call",
            prompt: "Search Gmail for unread messages",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(
                        id: "1",
                        name: "plugin_call",
                        arguments: "{\"slug\":\"gmail\",\"action\":\"search\",\"query\":\"unread\"}"
                    ),
                ]),
                ChatCompletionResponse(text: "Found 3 unread threads."),
            ],
            expectedTools: ["plugin_call"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-09 run_subagent spawns helper")
    func subagent() async throws {
        let spec = AgentEvalSpec(
            name: "run_subagent",
            prompt: "Spawn a helper to summarize the inbox",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(
                        id: "1",
                        name: "run_subagent",
                        arguments: "{\"title\":\"Summarize inbox\",\"prompt\":\"Summarize unread mail\"}"
                    ),
                ]),
                ChatCompletionResponse(text: "Started a helper run."),
            ],
            expectedTools: ["run_subagent"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-10 search_memory tool available")
    func searchMemoryTool() {
        let tools = AgentToolCatalog.chatTools(enabledIds: AgentToolCatalog.allIds)
        #expect(tools.contains(where: { $0.function.name == "search_memory" }))
    }

    @Test("CI-11 multi-step write then read")
    func writeThenRead() async throws {
        let spec = AgentEvalSpec(
            name: "write_then_read",
            prompt: "Write notes/out.txt then read it back",
            responses: [
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"notes/out.txt\",\"content\":\"ping\"}"),
                ]),
                ChatCompletionResponse(toolCalls: [
                    LLMToolCall(id: "2", name: "read_file", arguments: "{\"path\":\"notes/out.txt\"}"),
                ]),
                ChatCompletionResponse(text: "File contains ping"),
            ],
            expectedTools: ["write_file", "read_file"],
            expectedTextContains: ["ping"]
        )
        _ = try await AgentEvalRunner.runLoop(spec: spec)
    }

    @Test("CI-12 import_skills in catalog")
    func importSkillsTool() {
        let tools = AgentToolCatalog.chatTools(enabledIds: AgentToolCatalog.allIds)
        #expect(tools.contains(where: { $0.function.name == "import_skills" }))
    }

    @Test("CI-13 compaction preserves head and tail")
    func compaction() {
        let payload = "START-" + String(repeating: "m", count: 5000) + "-END"
        let compact = ContextCompactor.summarizePayload(payload)
        #expect(compact.contains("START-"))
        #expect(compact.contains("-END"))
        #expect(compact.count < payload.count)
    }

    @Test("CI-14 honest computer system prompt")
    func honestComputerPrompt() {
        let empty = AgentLoop.systemPrompt(for: AgentLoopRequest(
            endpoint: AgentEvalRunner.testEndpoint(),
            botName: "EvalBot",
            prompt: "hi",
            tools: [],
            computerNote: ""
        ))
        #expect(!empty.contains("You have a live computer"))

        let withNote = AgentLoop.systemPrompt(for: AgentLoopRequest(
            endpoint: AgentEvalRunner.testEndpoint(),
            botName: "EvalBot",
            prompt: "hi",
            tools: [],
            computerNote: "In-app browser session"
        ))
        #expect(withNote.contains("In-app browser session"))
    }

    @Test("CI-15 store routes write_file tool call")
    @MainActor
    func storeWriteFile() async {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-ci@test.com", password: "password1") == nil)
        let bot = store.createBot(name: "Writer", title: "files")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"notes/ci.txt\",\"content\":\"ci-pass\"}"),
            ]),
            ChatCompletionResponse(text: "Wrote notes/ci.txt"),
        ])
        store.send(botId: bot.id, text: "write ci.txt")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let text = store.threads[bot.id]?.messages.last?.firstText ?? ""
        #expect(text.contains("ci") || text.contains("Wrote"))
    }

    @Test("CI-16 store routes remember tool call")
    @MainActor
    func storeRemember() async {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-remember@test.com", password: "password1") == nil)
        let bot = store.createBot(name: "Memory", title: "facts")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "remember", arguments: "{\"content\":\"Favorite color is blue\",\"scope\":\"bot\"}"),
            ]),
            ChatCompletionResponse(text: "Remembered."),
        ])
        store.send(botId: bot.id, text: "remember my favorite color")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.memory.contains(where: { $0.content.contains("blue") }))
    }

    @Test("CI-17 store shell gate without autoApprove")
    @MainActor
    func storeShellGate() async {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-shell@test.com", password: "password1") == nil)
        let bot = store.createBot(name: "Shell", title: "cmd")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "shell", arguments: "{\"command\":\"echo ci\"}"),
            ]),
            ChatCompletionResponse(text: "waiting"),
        ])
        store.send(botId: bot.id, text: "run echo")
        #expect(await store.waitForPendingTool(botId: bot.id))
        #expect(store.threads[bot.id]?.pendingTool?.tool == "shell.exec")
    }

    @Test("CI-18 store plugin_call uses Composio mock")
    @MainActor
    func storePluginCall() async {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-plugin@test.com", password: "password1") == nil)
        store.composioClient = ImmediateComposio()
        store.connect(slug: "gmail")
        await store.waitForPluginTasks()
        let bot = store.createBot(name: "Mail", title: "inbox")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(
                    id: "1",
                    name: "plugin_call",
                    arguments: "{\"slug\":\"gmail\",\"action\":\"search\",\"query\":\"unread\"}"
                ),
            ]),
            ChatCompletionResponse(text: "mail found"),
        ])
        store.send(botId: bot.id, text: "check gmail")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let text = store.threads[bot.id]?.messages.last?.firstText ?? ""
        #expect(text.contains("mail") || !text.isEmpty)
    }

    @Test("CI-19 search_memory does not leak sibling bot memory")
    @MainActor
    func siblingMemoryIsolation() {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-mem@test.com", password: "password1") == nil)
        let alice = store.createBot(name: "Alice", title: "a")
        let bob = store.createBot(name: "Bob", title: "b")
        store.memory.append(MemoryDocument(id: "ma", botId: alice.id, path: "MEMORY.md", content: "- Alice zebra token"))
        store.memory.append(MemoryDocument(id: "mb", botId: bob.id, path: "MEMORY.md", content: "- Bob zebra token"))
        let hits = MemoryIndex.search(documents: store.memory, query: "zebra", botId: alice.id)
        #expect(hits.contains(where: { $0.snippet.contains("Alice") }))
        #expect(!hits.contains(where: { $0.snippet.contains("Bob") }))
    }

    @Test("CI-20 due routine without a model is skipped")
    @MainActor
    func routineSkipNoModel() {
        let store = AgentEvalRunner.tempStore()
        #expect(store.signUp(name: "Eval", email: "eval-routine@test.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.openNewRoutine()
        store.routineDraft.name = "Ping"
        store.routineDraft.prompt = "say hi"
        store.routineDraft.botId = bot.id
        store.saveRoutineDraft()
        if let idx = store.routines[bot.id]?.indices.first {
            store.routines[bot.id]?[idx].nextRunAt = Date.now.addingTimeInterval(-60)
            store.routines[bot.id]?[idx].active = true
        }
        store.tickDueRoutines()
        #expect(store.routines[bot.id]?.first?.lastRunAt != nil)
        let texts = store.threads[bot.id]?.messages.map(\.firstText).joined(separator: " ") ?? ""
        let meta = store.threads[bot.id]?.messages.contains(where: { message in
            message.blocks.contains { block in
                if case .meta(let text) = block { return text.contains("skipped") }
                return false
            }
        }) == true
        #expect(meta || texts.contains("skipped"))
    }
}

@Suite("Agent live eval")
struct AgentLiveEvalTests {
    @Test(
        "live model picks write_file for a create-file prompt",
        .enabled(if: ProcessInfo.processInfo.environment["GRIZZYBOT_LIVE_EVAL"] == "1")
    )
    func liveWriteFile() async throws {
        let provider = ProcessInfo.processInfo.environment["GRIZZYBOT_EVAL_PROVIDER"] ?? "openai"
        let model = ProcessInfo.processInfo.environment["GRIZZYBOT_EVAL_MODEL"] ?? "gpt-4o-mini"
        let key = ProcessInfo.processInfo.environment["GRIZZYBOT_EVAL_API_KEY"] ?? ""
        let base = ProcessInfo.processInfo.environment["GRIZZYBOT_EVAL_BASE_URL"]
        try #require(!key.isEmpty)

        let recorder = ToolCallRecorder()
        let endpoint = try LLMRouting.endpoint(provider: provider, modelId: model, apiKey: key, baseUrl: base)
        let result = try await AgentLoop.run(
            client: OpenAIChatClient.shared,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "EvalBot",
                prompt: "Create notes/hello.txt containing exactly hello world. Use write_file.",
                tools: AgentToolCatalog.chatTools(enabledIds: ["write_file"]),
                maxSteps: 4
            )
        ) { name, args in
            recorder.record(name: name, arguments: args)
        }
        #expect(recorder.tools.contains("write_file"))
        #expect(!result.text.isEmpty || recorder.tools.contains("write_file"))
    }
}
