import Foundation
import GrizzyBotCore
import Testing

@Suite("Skills")
struct SkillsTests {
    @Test("parses SKILL.md frontmatter")
    func parseFrontmatter() throws {
        let raw = """
        ---
        name: research
        description: Search the web and cite sources.
        allowed-tools: [web_search, web_fetch]
        ---

        # Research
        Use web_search first.
        """
        let skill = try SkillMarkdown.parse(raw, fallbackId: "fallback", source: .user)
        #expect(skill.id == "research")
        #expect(skill.description.contains("cite"))
        #expect(skill.body.contains("web_search first"))
        #expect(skill.allowedTools == ["web_search", "web_fetch"])
    }

    @Test("research skill stops after failed search and prefers local settings")
    func researchStopsOnFailure() {
        let body = BundledSkills.research.body.lowercased()
        #expect(body.contains("if search fails"))
        #expect(body.contains("this mac") || body.contains("settings"))
        #expect(body.contains("do not keep retrying") || body.contains("do not retry"))
        #expect(body.contains("mcp_call"))
        #expect(body.contains("toolport") || body.contains("github__"))
        #expect(BundledSkills.research.allowedTools.contains("mcp_call"))
    }

    @Test("rejects missing description")
    func missingDescription() {
        let raw = """
        ---
        name: empty
        ---
        body
        """
        #expect(throws: SkillParseError.missingDescription) {
            _ = try SkillMarkdown.parse(raw, fallbackId: "empty", source: .user)
        }
    }

    @Test("catalog lists ids")
    func catalog() {
        let text = SkillMarkdown.catalogPrompt(from: BundledSkills.all)
        #expect(text.contains("research:"))
        #expect(text.contains("read_skill"))
        #expect(BundledSkills.ids.contains("office-docs"))
    }

    @Test("user skills persist on disk")
    func userSkillRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skill = AgentSkill(
            id: "my-brief",
            name: "my-brief",
            description: "Write a one-page brief.",
            body: "Always write notes/brief.md",
            source: .user
        )
        try SkillLibrary.saveUserSkill(skill, root: dir)
        let loaded = SkillLibrary.load(root: dir)
        #expect(loaded.contains(where: { $0.id == "my-brief" && $0.source == .user }))
        #expect(loaded.contains(where: { $0.id == "research" && $0.source == .bundled }))
        try SkillLibrary.deleteUserSkill(id: "my-brief", root: dir)
        #expect(!SkillLibrary.loadUserSkills(root: dir).contains(where: { $0.id == "my-brief" }))
    }

    @Test("imports SKILL.md files from a host folder")
    func importHostSkills() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-src-\(UUID().uuidString)", isDirectory: true)
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("orchestration"), withIntermediateDirectories: true)
        let raw = """
        ---
        name: orchestration
        description: Coordinate multiple agents with a task graph.
        ---
        Use spawn_bot and run_subagent. Do not keep retrying empty searches.
        """
        try raw.write(
            to: src.appendingPathComponent("orchestration/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let imported = try SkillLibrary.importFromDirectory(src, into: destRoot)
        #expect(imported.contains(where: { $0.id == "orchestration" }))
        #expect(SkillLibrary.loadUserSkills(root: destRoot).contains(where: { $0.id == "orchestration" }))
    }
}

@Suite("Bot templates and shared memory")
@MainActor
struct AbilityStoreTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
    }

    @Test("template sets skills")
    func templateSkills() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "tpl@b.com", password: "password1") == nil)
        let bot = store.createBot(from: BotTemplates.researcher)
        #expect(bot.name == "Researcher")
        #expect(bot.enabledSkills.contains("research"))
        #expect(!bot.enabledSkills.contains("coding"))
        #expect(store.skills.contains(where: { $0.id == "research" }))
    }

    @Test("shared memory is visible to every bot")
    func sharedMemory() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "mem@b.com", password: "password1") == nil)
        store.setSharedMemory("# Shared memory\n\n- house style is terse\n")
        #expect(store.sharedMemory.contains("terse"))
        let prompt = AgentLoop.systemPrompt(
            for: AgentLoopRequest(
                endpoint: ModelEndpoint(provider: "x", model: "y", baseURL: "https://x", apiKey: "k"),
                botName: "Scout",
                sharedMemory: store.sharedMemory,
                skillCatalog: SkillMarkdown.catalogPrompt(from: BundledSkills.all),
                prompt: "hi",
                tools: []
            )
        )
        #expect(prompt.contains("house style is terse"))
        #expect(prompt.contains("research:"))
    }

    @Test("LLM read_skill and remember shared")
    func skillToolAndSharedRemember() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "sk@b.com", password: "password1") == nil)
        let bot = store.createBot(from: BotTemplates.researcher)
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [
                    LLMToolCall(id: "1", name: "read_skill", arguments: "{\"id\":\"research\"}"),
                    LLMToolCall(
                        id: "2",
                        name: "remember",
                        arguments: "{\"content\":\"Prefer primary sources\",\"scope\":\"shared\"}"
                    ),
                ]
            ),
            ChatCompletionResponse(text: "loaded the research skill.", inputTokens: 4, outputTokens: 3),
        ])
        store.send(botId: bot.id, text: "use the research skill")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.sharedMemory.contains("Prefer primary sources"))
        let system = store.threads[bot.id]?.llmMessages
        _ = system
        #expect(store.messages(for: bot.id).contains(where: { $0.firstText.contains("loaded the research") }))
    }

    @Test("attachments land in bot home")
    func attachments() async throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "att@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent")
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).txt")
        try "hello-attach".write(to: src, atomically: true, encoding: .utf8)
        store.send(botId: bot.id, text: "look at this", attaching: [src])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(store.readBotHomeFile(botId: bot.id, path: "inbox/\(src.lastPathComponent)") == "hello-attach")
        #expect(store.messages(for: bot.id).contains(where: { $0.role == .user && $0.firstText.contains("inbox/") }))
    }
}
