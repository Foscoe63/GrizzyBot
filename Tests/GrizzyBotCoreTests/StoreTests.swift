import Foundation
import GrizzyBotCore
import Testing

@Suite("AppStore")
@MainActor
struct StoreTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return store
    }

    @Test("signUp validation")
    func signUpValidation() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "a@b.com", password: "short") != nil)
        #expect(store.signUp(name: "A", email: "a@b.com", password: "password1") == nil)
        let dup = store.signUp(name: "B", email: "a@b.com", password: "password2")
        #expect(dup == "An account with this email already exists.")
    }

    @Test("signIn wrong password")
    func signInWrong() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "a@b.com", password: "password1") == nil)
        store.signOut()
        #expect(store.signIn(email: "a@b.com", password: "wrongpass") == "Invalid login credentials")
    }

    @Test("bot color cycling and update/delete keeps children")
    func bots() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "bots@b.com", password: "password1") == nil)
        let first = store.createBot(name: "One", title: "t1")
        #expect(first.color == "#3EC5A8")
        let second = store.createBot(name: "Two", title: "t2")
        #expect(second.color == "#F5A03C")
        let child = store.createBot(name: "Child", title: "kid", parentBotId: first.id)
        store.updateBot(botId: first.id, name: "OneRenamed", title: "T")
        #expect(store.bots.first(where: { $0.id == first.id })?.name == "OneRenamed")
        store.deleteBot(first.id)
        #expect(store.bots.contains(where: { $0.id == child.id }))
        #expect(!store.bots.contains(where: { $0.id == first.id }))
        _ = second
    }

    @Test("deleting last bot routes to onboarding")
    func deleteLastBot() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "last@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Only")
        store.route = .shell
        store.deleteBot(bot.id)
        #expect(store.bots.isEmpty)
        #expect(store.route == .onboarding)
    }

    @Test("open computer takes control; release closes overlay")
    func openComputerWiring() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "ov@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent")
        store.openComputerOverlay()
        #expect(store.computerOpen)
        #expect(store.computers[bot.id]?.controlHolder == .user)
        #expect(await store.waitForComputerState(botId: bot.id, state: .running))
        store.release(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .bot)
        #expect(!store.computerOpen)
    }

    @Test("send completes run and records usage")
    func sendLoop() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "send@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.send(botId: bot.id, text: "hello there")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let msgs = store.messages(for: bot.id)
        #expect(msgs.contains(where: { $0.role == .user }))
        #expect(msgs.contains(where: { $0.role == .bot && $0.firstText.contains("on it.") }))
        #expect(store.threads[bot.id]?.run?.status == .completed)
        #expect(store.usage.last?.inputTokens == 12)
        #expect(store.usage.last?.outputTokens == 40)
        #expect(!store.sidebarPreview(for: store.bots.first!).isEmpty)
    }

    @Test("LLM agent writes files via tool calls")
    func llmAgentLoop() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "llm@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper", instructions: "Use tools.")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [
                    LLMToolCall(
                        id: "1",
                        name: "write_file",
                        arguments: "{\"path\":\"notes/result.txt\",\"content\":\"agent-ok\"}"
                    ),
                ]
            ),
            ChatCompletionResponse(text: "saved it in your files.", inputTokens: 8, outputTokens: 5),
        ])
        store.send(botId: bot.id, text: "write notes/result.txt")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let msgs = store.messages(for: bot.id)
        #expect(msgs.contains(where: { $0.role == .bot && $0.firstText.contains("saved it") }))
        #expect(store.readBotHomeFile(botId: bot.id, path: "notes/result.txt") == "agent-ok")
        #expect(store.threads[bot.id]?.run?.status == .completed)
        #expect(store.usage.last?.inputTokens == 8)
        #expect(store.usage.last?.outputTokens == 5)
        #expect(!(store.threads[bot.id]?.llmMessages.isEmpty ?? true))
    }

    @Test("stopRun cancels")
    func stopRun() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "stop@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.send(botId: bot.id, text: "hello")
        store.stopRun(botId: bot.id)
        #expect(store.threads[bot.id]?.run?.status == .cancelled)
    }

    @Test("routine create and runNow appends meta")
    func routines() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "routine@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        _ = store.createRoutine(
            botId: bot.id,
            name: "Morning",
            prompt: "say hi",
            cron: "0 9 * * *"
        )
        store.runNow(botId: bot.id)
        #expect(await store.waitForRunCompletion(botId: bot.id, timeout: 5))
        let msgs = store.messages(for: bot.id)
        #expect(msgs.contains(where: { msg in
            msg.blocks.contains { if case .meta(let t) = $0 { return t.contains("Morning") }; return false }
        }))
    }

    @Test("computer boot takeControl release")
    func computer() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "comp@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.boot(botId: bot.id, force: true)
        #expect(store.computers[bot.id]?.state == .booting)
        #expect(await store.waitForComputerState(botId: bot.id, state: .running))
        store.takeControl(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .user)
        store.release(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .bot)
    }

    @Test("plugins connect revoke")
    func plugins() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "plug@b.com", password: "password1") == nil)
        store.connect(slug: "gmail", token: "test-token")
        await store.waitForPluginTasks()
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == true)
        store.revoke(slug: "gmail")
        await store.waitForPluginTasks()
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
    }

    @Test("plugins without Composio open the token sheet")
    func pluginsTokenSheet() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "token@b.com", password: "password1") == nil)
        store.connect(slug: "gmail")
        #expect(store.connectingSlug == "gmail")
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
    }

    @Test("plugins Composio OAuth marks the app connected")
    func pluginsComposioOAuth() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "oauth@b.com", password: "password1") == nil)
        let composio = ImmediateComposio()
        store.composioClient = composio
        store.connect(slug: "gmail")
        await store.waitForPluginTasks()
        #expect(composio.lastAuthorize == "gmail")
        let gmail = store.connections.first(where: { $0.slug == "gmail" })
        #expect(gmail?.connected == true)
        #expect(gmail?.viaComposio == true)
        #expect(store.connectingSlug == nil)
        store.revoke(slug: "gmail")
        await store.waitForPluginTasks()
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.viaComposio == false)
    }

    @Test("bot memory is a file, upserts similar facts, and forgets")
    func memoryFilesAndUpsert() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "memfile@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Keeper", title: "facts")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "remember", arguments: "{\"content\":\"Favorite color is blue\"}"),
            ]),
            ChatCompletionResponse(text: "ok"),
        ])
        store.send(botId: bot.id, text: "remember color")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.botMemory(botId: bot.id).contains("blue"))
        #expect(store.readBotHomeFile(botId: bot.id, path: "MEMORY.md")?.contains("blue") == true)

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "remember", arguments: "{\"content\":\"Favorite color is red\"}"),
            ]),
            ChatCompletionResponse(text: "ok"),
        ])
        store.send(botId: bot.id, text: "remember color again")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let after = store.botMemory(botId: bot.id)
        #expect(after.contains("red"))
        #expect(!after.contains("blue"))

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "forget", arguments: "{\"query\":\"favorite color\"}"),
            ]),
            ChatCompletionResponse(text: "ok"),
        ])
        store.send(botId: bot.id, text: "forget the color")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(!store.botMemory(botId: bot.id).contains("red"))
    }

    @Test("remember pin:true writes ## Pin")
    func rememberPin() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "pin@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Pinbot", title: "facts")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "remember", arguments: "{\"content\":\"Always be terse\",\"pin\":\"true\"}"),
            ]),
            ChatCompletionResponse(text: "ok"),
        ])
        store.send(botId: bot.id, text: "pin that")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let memory = store.botMemory(botId: bot.id)
        let pinSection = memory.components(separatedBy: "## Facts").first ?? ""
        #expect(pinSection.contains("Always be terse"))
    }

    @Test("weeklySummary math")
    func weekly() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "week@b.com", password: "password1") == nil)
        store.usage = [
            UsageRecord(id: Ids.new(), provider: "p", model: "m", inputTokens: 10, outputTokens: 20),
            UsageRecord(id: Ids.new(), provider: "p", model: "m", inputTokens: 5, outputTokens: 7),
        ]
        let summary = store.weeklySummary()
        #expect(summary.runs == 2)
        #expect(summary.inputTokens == 15)
        #expect(summary.outputTokens == 27)
    }

    @Test("clear save export restore and wipe session")
    func sessionLifecycle() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "sess@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.send(botId: bot.id, text: "hello there")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.activeSessionMessageCount > 0)

        let export = store.exportActiveChat()
        #expect(export?.messages.isEmpty == false)
        #expect(store.exportActiveChatJSON() != nil)
        #expect(store.exportActiveChatMarkdown().contains("hello there"))

        let snap = store.saveWorkspaceSnapshot(name: "Before clear")
        #expect(snap?.name == "Before clear")
        #expect(store.listWorkspaceSnapshots().count == 1)

        store.clearActiveChat()
        #expect(store.activeSessionMessageCount == 0)

        #expect(store.restoreWorkspaceSnapshot(snap!.id))
        #expect(store.activeSessionMessageCount > 0)

        store.deleteWorkspace()
        #expect(store.bots.isEmpty)
        #expect(store.threads.isEmpty)
        #expect(store.route == .onboarding)
        #expect(store.listWorkspaceSnapshots().count == 1)
    }

    @Test("Box.com key seeds the Box plugin without Composio")
    func boxKeySeedsPlugin() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "box@b.com", password: "password1") == nil)
        #expect(ConnectionCatalog.defaults.contains(where: { $0.slug == "box" }))
        var config = store.appConfig
        config.boxToken = "box_dev_token"
        store.saveAppConfig(config)
        #expect(store.appConfig.boxConfigured)
        #expect(store.connectionSecrets["box"] == "box_dev_token")
        #expect(store.connections.first(where: { $0.slug == "box" })?.connected == true)
        #expect(PluginClient.tokenHint(for: "box").lowercased().contains("box"))
    }

    @Test("updateMcpServer keeps id and rewrites command")
    func updateMcpServer() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "mcp@b.com", password: "password1") == nil)
        let added = try #require(store.addMcpServer(
            name: "filesystem",
            transport: .stdio,
            command: "npx",
            args: ["-y", "old"],
            env: ["A": "1"],
            url: "",
            headers: [:]
        ))
        var edited = added
        edited.name = "files"
        edited.command = "uvx"
        edited.args = ["mcp-server"]
        edited.env = ["B": "2"]
        store.updateMcpServer(edited)
        let saved = store.mcpServers.first(where: { $0.id == added.id })
        #expect(saved?.name == "files")
        #expect(saved?.command == "uvx")
        #expect(saved?.args == ["mcp-server"])
        #expect(saved?.env["B"] == "2")
        #expect(store.mcpServers.count == 1)
    }

    @Test("addToolkit copies a Composio catalog item into connections")
    func addToolkitFromCatalog() async throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "tk@b.com", password: "password1") == nil)
        let composio = ImmediateComposio()
        composio.catalog = ConnectionCatalog.defaults + [
            ConnectionItem(slug: "clickup", name: "ClickUp", logo: "https://example.com/c.png", blurb: "Tasks and docs"),
        ]
        store.composioClient = composio
        await store.browseComposioCatalog(query: "")
        #expect(store.composioCatalog.contains(where: { $0.slug == "clickup" }))
        #expect(!store.connections.contains(where: { $0.slug == "clickup" }))

        await store.browseComposioCatalog(query: "click")
        #expect(store.composioCatalog.map(\.slug) == ["clickup"])

        let item = try #require(store.composioCatalog.first(where: { $0.slug == "clickup" }))
        let added = try #require(store.addToolkit(item))
        #expect(added.slug == "clickup")
        #expect(store.connections.contains(where: { $0.slug == "clickup" && $0.name == "ClickUp" }))
        #expect(store.addToolkit(slug: "  ") == nil)
        #expect(store.addToolkit(slug: "ClickUp")?.slug == "clickup")
        #expect(store.connections.filter { $0.slug == "clickup" }.count == 1)
    }
}
