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

    @Test("the profile can toggle every skill in the library, user skills included")
    func perBotSkillToggles() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "toggle@b.com", password: "password1") == nil)
        try store.installUserSkill(id: "House Style", description: "Write like us", body: "# House style")
        let bot = store.createBot(from: BotTemplates.researcher)

        // Every bundled skill plus the user's own is offered, not just the template's.
        #expect(store.skills.count == BundledSkills.all.count + 1)
        #expect(store.skills.contains(where: { $0.id == "house-style" && $0.source == .user }))

        store.setAllBotSkills(bot.id, enabled: false)
        #expect(store.bots.first(where: { $0.id == bot.id })?.enabledSkills.isEmpty == true)
        #expect(store.enabledSkills(for: bot.id).isEmpty)

        store.setBotSkill(bot.id, skillId: "coding", enabled: true)
        #expect(store.enabledSkills(for: bot.id).map(\.id) == ["coding"])

        store.setAllBotSkills(bot.id, enabled: true)
        #expect(Set(store.enabledSkills(for: bot.id).map(\.id)) == Set(store.skills.map(\.id)))
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

    @Test("a user skill sharing a bundled id does not trap the matcher")
    func duplicateSkillIdIsSurvivable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-dup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let override = AgentSkill(
            id: BundledSkills.skillCreator.id,
            name: BundledSkills.skillCreator.name,
            description: "My own take on authoring a SKILL.md file.",
            body: "# Mine\nDo it my way.",
            source: .user
        )
        try SkillLibrary.saveUserSkill(override, root: root)

        let loaded = SkillLibrary.load(root: root)
        let creators = loaded.filter { $0.id == BundledSkills.skillCreator.id }
        #expect(creators.count == 1)
        #expect(creators.first?.source == .user)
        #expect(creators.first?.description == override.description)

        // Would have trapped in Dictionary(uniqueKeysWithValues:) before the dedupe.
        let matched = SkillMarkdown.matching(loaded, prompt: "author a new skill file")
        #expect(matched.allSatisfy { loaded.contains($0) })

        // Even if a duplicate reaches the matcher directly, it must rank, not crash.
        let withDupes = BundledSkills.all + [override]
        let fromDupes = SkillMarkdown.matching(withDupes, prompt: "author a new skill file")
        #expect(!fromDupes.isEmpty)
    }

    @Test("action snippets append with one blank line between steps")
    func actionSnippetsAppend() {
        let first = SkillActions.append(SkillActions.progress, to: "")
        #expect(first == SkillActions.progress.snippet)
        #expect(!first.hasPrefix("\n"))

        let second = SkillActions.append(SkillActions.ask, to: first)
        #expect(second.contains(SkillActions.progress.snippet))
        #expect(second.hasSuffix(SkillActions.ask.snippet))
        #expect(!second.contains("\n\n\n"))

        // Trailing whitespace in the editor must not widen the gap.
        let padded = SkillActions.append(SkillActions.ask, to: first + "\n\n  \n")
        #expect(!padded.contains("\n\n\n"))
    }

    @Test("every editor action names a tool a bot can actually call")
    func actionSnippetsNameRealTools() throws {
        let alwaysOn = Set(["todo", "complete", "clarify"])
        let bare = Bot(id: "b", name: "Bare", color: "#fff", threadId: "t", enabledTools: [], enabledSkills: [])
        for action in SkillActions.all {
            #expect(!action.label.isEmpty)
            #expect(!action.summary.isEmpty)
            // `confirm` is a usage pattern built on clarify, not a tool of its own.
            let tool = action.id == "confirm" ? "clarify" : action.id
            #expect(
                AgentToolCatalog.builtinIds.contains(tool),
                "\(action.id) references unknown tool \(tool)"
            )
            #expect(action.snippet.contains("`\(tool)`"))
            if alwaysOn.contains(tool) {
                // Always-on tools stay callable even with every tool switched off.
                #expect(bare.isToolEnabled(tool), "\(tool) should not need enabling")
            }
        }
    }


    @Test("a skill opens as an artifact and saving the document writes the skill")
    func skillRoundTripsThroughTheArtifactEditor() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "artifact@b.com", password: "password1") == nil)
        try store.installUserSkill(
            AgentSkill(
                id: "tidy",
                name: "tidy",
                description: "Tidy a folder",
                body: "# Tidy\n\nMove files.",
                source: .user,
                allowedTools: ["list_files", "move_file"],
                keywords: ["organize", "tidy"]
            )
        )

        let opened = try #require(store.openSkillInEditor("tidy"))
        #expect(opened.linkedSkillId == "tidy")
        #expect(opened.kind == .markdown)
        // The whole file, so frontmatter is editable — not just the body.
        #expect(opened.content.contains("description: Tidy a folder"))
        #expect(opened.content.contains("keywords: [organize, tidy]"))
        #expect(store.panel == .artifact)

        let edited = opened.content
            .replacingOccurrences(of: "Tidy a folder", with: "Tidy any folder")
            .replacingOccurrences(of: "Move files.", with: "Move files carefully.")
        let outcome = store.saveArtifactEdit(
            id: opened.id,
            content: edited,
            baseVersionCount: opened.versions.count
        )
        #expect(outcome == .saved)

        let saved = try #require(store.skills.first(where: { $0.id == "tidy" }))
        #expect(saved.description == "Tidy any folder")
        #expect(saved.body.contains("carefully"))
        // Fields the three-field form has no box for survive the round trip.
        #expect(saved.allowedTools == ["list_files", "move_file"])
        #expect(saved.keywords == ["organize", "tidy"])
        // And it reached disk, not just the in-memory list: reloadSkills re-reads
        // the library folder.
        store.reloadSkills()
        #expect(store.skills.first(where: { $0.id == "tidy" })?.description == "Tidy any folder")
    }

    @Test("a skill document that no longer parses is refused, not saved")
    func brokenSkillDocumentIsRefused() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "broken@b.com", password: "password1") == nil)
        try store.installUserSkill(id: "tidy", description: "Tidy a folder", body: "# Tidy")
        let opened = try #require(store.openSkillInEditor("tidy"))

        let outcome = store.saveArtifactEdit(
            id: opened.id,
            content: "# Tidy\n\nNo frontmatter at all.",
            baseVersionCount: opened.versions.count
        )
        guard case .failed = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        // The library still holds the version that parsed.
        #expect(store.skills.first(where: { $0.id == "tidy" })?.description == "Tidy a folder")
        // And the artifact was not given a version recording content the library rejected.
        #expect(store.artifact(id: opened.id)?.content == opened.content)
    }

    @Test("reopening a skill does not pile up artifact versions")
    func reopeningDoesNotAddVersions() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "reopen@b.com", password: "password1") == nil)
        try store.installUserSkill(id: "tidy", description: "Tidy a folder", body: "# Tidy")

        let first = try #require(store.openSkillInEditor("tidy"))
        let again = try #require(store.openSkillInEditor("tidy"))
        #expect(again.versions.count == first.versions.count)

        // But an edit made elsewhere does reseed, so the document is never stale.
        try store.installUserSkill(id: "tidy", description: "Tidy a folder", body: "# Tidy\n\nChanged.")
        let reseeded = try #require(store.openSkillInEditor("tidy"))
        #expect(reseeded.content.contains("Changed."))
        #expect(reseeded.versions.count == first.versions.count + 1)
    }

}
