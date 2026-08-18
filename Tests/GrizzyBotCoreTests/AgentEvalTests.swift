import Foundation
import GrizzyBotCore
import Testing

@Suite("Memory and diffs")
struct MemoryDiffTests {
    @Test("search_memory ranks overlapping lines")
    func searchHits() {
        let docs = [
            MemoryDocument(
                id: "1",
                botId: "b",
                path: "MEMORY.md",
                content: "# Memory\n\n- Alice prefers Linear\n- Deploy Fridays only\n"
            ),
            MemoryDocument(
                id: "2",
                scope: "workspace",
                path: "SHARED.md",
                content: "# Shared memory\n\n- Company domain is example.com\n"
            ),
        ]
        let hits = MemoryIndex.search(documents: docs, query: "linear alice")
        #expect(hits.contains(where: { $0.snippet.lowercased().contains("linear") }))
        #expect(!hits.contains(where: { $0.snippet.contains("Fridays") && !$0.snippet.lowercased().contains("linear") }))
    }

    @Test("excerpt truncates long memory")
    func excerpt() {
        let long = String(repeating: "fact ", count: 800)
        let text = MemoryIndex.excerpt(long, maxChars: 80)
        #expect(text.contains("search_memory"))
        #expect(text.count < long.count)
    }

    @Test("unified diff marks new and changed lines")
    func diff() {
        let diff = TextDiff.unified(before: "hello\nworld", after: "hello\nthere", path: "a.txt")
        #expect(diff.contains("- world"))
        #expect(diff.contains("+ there"))
        let created = TextDiff.unified(before: "", after: "new", path: "b.txt")
        #expect(created.contains("new file") || created.contains("+ new"))
    }
}

@Suite("Skill matching")
struct SkillMatchTests {
    @Test("injects the research skill for a search prompt")
    func matchResearch() {
        let matched = SkillMarkdown.matching(BundledSkills.all, prompt: "search the web for otter facts")
        #expect(matched.contains(where: { $0.id == "research" }))
        let prompt = SkillMarkdown.catalogPrompt(from: BundledSkills.all, injected: matched)
        #expect(prompt.contains("Matched skills"))
        #expect(prompt.contains("read_skill"))
    }
}

@Suite("Agent evals")
struct AgentEvalTests {
    private func endpoint() -> ModelEndpoint {
        ModelEndpoint(provider: "openrouter", model: "test", baseURL: "https://example.com/v1", apiKey: "k")
    }

    @Test("eval 1 write file then confirm")
    func writeFile() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "write_file", arguments: "{\"path\":\"notes/a.txt\",\"content\":\"hi\"}")]),
            ChatCompletionResponse(text: "wrote notes/a.txt"),
        ])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: endpoint(), botName: "Scout", prompt: "write a file", tools: [])
        ) { _, _ in
            AgentToolCallResult(output: "Wrote notes/a.txt")
        }
        #expect(result.text.contains("wrote"))
        #expect(client.requests.count == 2)
    }

    @Test("eval 2 search then fetch in one step")
    func searchAndFetchParallel() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "web_search", arguments: "{\"query\":\"otters\"}"),
                LLMToolCall(id: "2", name: "web_fetch", arguments: "{\"url\":\"https://example.com\"}"),
            ]),
            ChatCompletionResponse(text: "otters are mammals"),
        ])
        let seen = QueueChatClient([])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: endpoint(), botName: "Scout", prompt: "research otters", tools: [])
        ) { name, _ in
            seen.lastToolName += name + ","
            return AgentToolCallResult(output: name)
        }
        #expect(seen.lastToolName.contains("web_search"))
        #expect(seen.lastToolName.contains("web_fetch"))
        #expect(result.text.contains("otters"))
    }

    @Test("eval 3 spawn helper schema exists")
    func spawnHelperTool() {
        let tools = AgentToolCatalog.chatTools(enabledIds: AgentToolCatalog.allIds)
        #expect(tools.contains(where: { $0.function.name == "run_subagent" }))
        #expect(tools.contains(where: { $0.function.name == "search_memory" }))
        #expect(tools.contains(where: { $0.function.name == "plugin_call" }))
    }

    @Test("eval 4 plugin search vs write")
    func pluginSearch() async {
        let composio = ImmediateComposio()
        let found = try? await composio.search(slug: "gmail", query: "unread")
        #expect(found == "composio-search://gmail/unread")
        let wrote = try? await composio.execute(slug: "gmail", title: "Hi", body: "body")
        #expect(wrote == "composio://gmail/Hi")
    }

    @Test("eval 5 memory search finds a fact")
    func memoryFact() {
        let docs = [
            MemoryDocument(id: "1", botId: "b", path: "MEMORY.md", content: "- Zendesk subdomain is acme.zendesk.com"),
        ]
        let hits = MemoryIndex.search(documents: docs, query: "zendesk subdomain")
        #expect(hits.first?.snippet.contains("acme.zendesk.com") == true)
    }

    @Test("eval 6 skill auto-inject contains body")
    func skillBody() {
        let matched = SkillMarkdown.matching(BundledSkills.all, prompt: "write a coding patch")
        let text = SkillMarkdown.catalogPrompt(from: BundledSkills.all, injected: matched)
        #expect(!matched.isEmpty)
        #expect(text.contains(matched[0].body.prefix(20)))
    }

    @Test("eval 7 shell pauses without auto-approve")
    func shellPause() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "shell", arguments: "{\"command\":\"ls\"}")]),
        ])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: endpoint(), botName: "Scout", prompt: "run ls", tools: [])
        ) { _, args in
            AgentToolCallResult(
                output: "Need approval",
                blocks: [.approval(tool: "shell.exec", detail: "ls", status: .pending)],
                pause: .approval(tool: "shell.exec", detail: "ls", arguments: args)
            )
        }
        #expect(result.pause == .approval(tool: "shell.exec", detail: "ls", arguments: "{\"command\":\"ls\"}"))
        if case .approval(_, _, .pending) = result.blocks.first { } else {
            #expect(result.blocks.contains(where: { if case .approval = $0 { return true }; return false }))
        }
    }

    @Test("eval 8 compaction summarizes instead of wiping")
    func compactKeepsHeadAndTail() {
        let payload = "HEAD-" + String(repeating: "x", count: 4000) + "-TAIL"
        let shrunk = ContextCompactor.summarizePayload(payload)
        #expect(shrunk.contains("HEAD-"))
        #expect(shrunk.contains("-TAIL"))
        #expect(shrunk.contains("summarized"))
        #expect(shrunk.count < payload.count)
    }

    @Test("eval 9 honest computer prompt")
    func honestComputer() {
        let request = AgentLoopRequest(
            endpoint: endpoint(),
            botName: "Scout",
            prompt: "hi",
            tools: [],
            computerNote: ""
        )
        let prompt = AgentLoop.systemPrompt(for: request)
        #expect(!prompt.contains("You have a live computer"))
        #expect(prompt.contains("no live session") || prompt.contains("Computer:"))
        let withNote = AgentLoop.systemPrompt(for: AgentLoopRequest(
            endpoint: endpoint(),
            botName: "Scout",
            prompt: "hi",
            tools: [],
            computerNote: "Persistent in-app browser"
        ))
        #expect(withNote.contains("Persistent in-app browser"))
    }

    @Test("eval 10 file write diff")
    func fileDiffEval() {
        let diff = TextDiff.unified(before: "alpha", after: "beta", path: "notes/result.txt")
        #expect(diff.contains("- alpha"))
        #expect(diff.contains("+ beta"))
    }
}

@Suite("Store robustness")
@MainActor
struct StoreRobustnessTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return store
    }

    @Test("shell without autoApprove pauses")
    func shellGate() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "gate@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "shell", arguments: "{\"command\":\"echo hi\"}")]),
            ChatCompletionResponse(text: "waiting"),
        ])
        store.send(botId: bot.id, text: "run echo hi")
        try? await Task.sleep(for: .milliseconds(400))
        let thread = store.threads[bot.id]
        #expect(thread?.pendingTool?.tool == "shell.exec")
        #expect(thread?.run?.status == .waitingInput)
    }

    @Test("plugin search uses Composio")
    func pluginRead() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "plug2@b.com", password: "password1") == nil)
        store.composioClient = ImmediateComposio()
        store.connect(slug: "gmail")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == true)
        let bot = store.createBot(name: "Mailer", title: "inbox")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [LLMToolCall(
                    id: "1",
                    name: "plugin_call",
                    arguments: "{\"slug\":\"gmail\",\"action\":\"search\",\"query\":\"unread\"}"
                )]
            ),
            ChatCompletionResponse(text: "you have mail"),
        ])
        store.send(botId: bot.id, text: "check gmail")
        try? await Task.sleep(for: .milliseconds(400))
        let text = store.threads[bot.id]?.messages.last?.firstText ?? ""
        #expect(text.contains("mail") || (store.threads[bot.id]?.messages.contains(where: { $0.blocks.contains { if case .card = $0 { return true }; return false } }) == true))
    }

    @Test("due routines fire")
    func routineTick() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "cron@b.com", password: "password1") == nil)
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
    }
}
