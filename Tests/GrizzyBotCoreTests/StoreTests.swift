import CoreGraphics
import Foundation
import GrizzyBotCore
import ImageIO
import Testing
import UniformTypeIdentifiers

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
        #expect(store.usage.last?.promptTokens == 12)
        let stats = store.chatTokenStats(botId: bot.id)
        #expect(stats.lastPromptTokens == 12)
        #expect(stats.sentTokens == 12)
        #expect(stats.receivedTokens == 40)
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
        var opened: [URL] = []
        store.openExternalURL = { opened.append($0) }
        store.connect(slug: "gmail")
        await store.waitForPluginTasks()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(composio.lastAuthorize == "gmail")
        #expect(!opened.isEmpty)
        let gmail = store.connections.first(where: { $0.slug == "gmail" })
        #expect(gmail?.connected == true)
        #expect(gmail?.viaComposio == true)
        #expect(store.connectingSlug == nil)
        store.revoke(slug: "gmail")
        await store.waitForPluginTasks()
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.viaComposio == false)
    }

    @Test("X Connect maps to Composio twitter toolkit")
    func pluginsComposioXTwitter() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "xoauth@b.com", password: "password1") == nil)
        let composio = ImmediateComposio()
        store.composioClient = composio
        var opened: [URL] = []
        store.openExternalURL = { opened.append($0) }
        store.connect(slug: "x")
        await store.waitForPluginTasks()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(composio.lastAuthorize == "x")
        #expect(composio.connected.contains("twitter"))
        #expect(!opened.isEmpty)
        #expect(store.connections.first(where: { $0.slug == "x" })?.connected == true)
    }

    @Test("syncComposioConnection picks up remote ACTIVE status")
    func syncComposioRemote() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "sync@b.com", password: "password1") == nil)
        let composio = ImmediateComposio()
        composio.connected.insert("gmail")
        store.composioClient = composio
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
        let ok = await store.syncComposioConnection(slug: "gmail")
        #expect(ok)
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == true)
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.viaComposio == true)
    }

    @Test("plugin account preference all fans out Composio searches")
    func pluginAccountAll() async throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "multi@b.com", password: "password1") == nil)
        let composio = ImmediateComposio()
        composio.connected.insert("gmail")
        composio.accountsBySlug["gmail"] = ["gmail_dayal-peiser", "gmail_lerwa-gharry"]
        store.composioClient = composio
        if let idx = store.connections.firstIndex(where: { $0.slug == "gmail" }) {
            store.connections[idx].connected = true
            store.connections[idx].viaComposio = true
        }
        store.connectionSecrets["gmail"] = ComposioClient.composioTokenSentinel
        store.setPluginAccountPreference(slug: "gmail", account: AppStore.pluginAccountAll)
        store.composioAccountChoices["gmail"] = ["gmail_dayal-peiser", "gmail_lerwa-gharry"]

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [
                LLMToolCall(id: "1", name: "plugin_call", arguments: "{\"slug\":\"gmail\",\"action\":\"search\",\"query\":\"in:inbox\"}"),
            ]),
            ChatCompletionResponse(text: "done"),
        ])
        let bot = store.createBot(name: "Mailbot", title: "mail")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[idx].autoApprove = true
        }
        store.send(botId: bot.id, text: "check mail")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        #expect(store.pluginAccountPreference(for: "gmail") == AppStore.pluginAccountAll)
        #expect(Set(composio.searchedAccounts) == Set(["gmail_dayal-peiser", "gmail_lerwa-gharry"]))
    }

    @Test("setPluginAccountPreference stores specific Gmail account")
    func pluginAccountSpecific() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "acct@b.com", password: "password1") == nil)
        store.setPluginAccountPreference(slug: "gmail", account: "gmail_lerwa-gharry")
        #expect(store.pluginAccountPreference(for: "gmail") == "gmail_lerwa-gharry")
        store.setPluginAccountPreference(slug: "gmail", account: nil)
        #expect(store.pluginAccountPreference(for: "gmail") == nil)
    }

    @Test("Google Client OAuth connects Gmail without Composio")
    func googleOAuthBypass() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "google@b.com", password: "password1") == nil)
        var config = store.appConfig
        config.googleClientId = "client.apps.googleusercontent.com"
        config.googleClientSecret = "secret"
        store.saveAppConfig(config)
        let google = ImmediateGoogleOAuth()
        store.googleOAuthClient = google
        store.connect(slug: "gmail")
        await store.waitForPluginTasks()
        #expect(google.authorizeCalls == 1)
        #expect(google.lastScopes.contains(where: { $0.contains("gmail") }))
        let gmail = store.connections.first(where: { $0.slug == "gmail" })
        #expect(gmail?.connected == true)
        #expect(gmail?.viaComposio == false)
        #expect(gmail?.accountLabel == "user@gmail.com")
        #expect(store.connectionSecrets[GoogleOAuth.credentialSecretKey] != nil)
    }

    @Test("Sign in with Google connects the suite")
    func googleSuiteConnect() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "suite@b.com", password: "password1") == nil)
        store.googleOAuthClient = ImmediateGoogleOAuth()
        store.connectGoogleSuite()
        await store.waitForPluginTasks()
        for slug in ["gmail", "google-calendar", "google-sheets", "google-docs", "google-drive"] {
            #expect(store.connections.first(where: { $0.slug == slug })?.connected == true)
        }
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

    @Test("chatTokenStats is per bot and prefers stored promptTokens")
    func chatTokenStatsPerBot() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "tok@b.com", password: "password1") == nil)
        let a = store.createBot(name: "A", title: "helper")
        let b = store.createBot(name: "B", title: "helper")
        store.usage = [
            UsageRecord(
                id: "1",
                botId: a.id,
                provider: "p",
                model: "m",
                promptTokens: 100,
                inputTokens: 140,
                outputTokens: 20,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            UsageRecord(
                id: "2",
                botId: a.id,
                provider: "p",
                model: "m",
                promptTokens: 80,
                inputTokens: 90,
                outputTokens: 10,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            UsageRecord(
                id: "3",
                botId: b.id,
                provider: "p",
                model: "m",
                inputTokens: 999,
                outputTokens: 1,
                createdAt: Date(timeIntervalSince1970: 3)
            ),
        ]
        let stats = store.chatTokenStats(botId: a.id)
        #expect(stats.lastPromptTokens == 80)
        #expect(stats.sentTokens == 230)
        #expect(stats.receivedTokens == 30)
        let other = store.chatTokenStats(botId: b.id)
        #expect(other.lastPromptTokens == 999)
        #expect(other.sentTokens == 999)
        #expect(other.receivedTokens == 1)
    }

    @Test("resetChatTokens zeros one bot and leaves chats")
    func resetChatTokensPerBot() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.signUp(name: "A", email: "reset-tok@b.com", password: "password1") == nil)
        let a = store.createBot(name: "A", title: "helper")
        let b = store.createBot(name: "B", title: "helper")
        var thread = store.threads[a.id] ?? ThreadData(threadId: a.threadId)
        thread.messages.append(
            ThreadMessage(
                id: "keep-1",
                threadId: thread.threadId,
                seq: 0,
                role: .user,
                blocks: [.text("keep this")]
            )
        )
        store.threads[a.id] = thread
        store.usage = [
            UsageRecord(
                id: "1",
                botId: a.id,
                provider: "p",
                model: "m",
                promptTokens: 80,
                inputTokens: 140,
                outputTokens: 20,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            UsageRecord(
                id: "2",
                botId: b.id,
                provider: "p",
                model: "m",
                inputTokens: 999,
                outputTokens: 1,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
        ]
        #expect(store.resetChatTokens(botId: a.id) == 1)
        let cleared = store.chatTokenStats(botId: a.id)
        #expect(cleared.lastPromptTokens == 0)
        #expect(cleared.sentTokens == 0)
        #expect(cleared.receivedTokens == 0)
        let other = store.chatTokenStats(botId: b.id)
        #expect(other.sentTokens == 999)
        #expect(store.messages(for: a.id).contains(where: { $0.role == .user }))

        let reloaded = AppStore(dataDirectory: dir, delayScale: 0.01)
        reloaded.pluginClient = AlwaysAllowPlugins()
        #expect(reloaded.chatTokenStats(botId: a.id).sentTokens == 0)
        #expect(reloaded.chatTokenStats(botId: b.id).sentTokens == 999)

        #expect(reloaded.resetChatTokens() == 1)
        #expect(reloaded.usage.isEmpty)
        #expect(reloaded.chatTokenStats(botId: b.id).sentTokens == 0)
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

    @Test("plugin slug twitter resolves to catalog x")
    func pluginSlugTwitterAlias() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "x@b.com", password: "password1") == nil)
        #expect(store.resolvePluginSlug("twitter") == "x")
        #expect(store.resolvePluginSlug("x") == "x")
        #expect(ComposioClient.toolkitSlug("x") == "twitter")
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

    @Test("shared canvas save open delete is visible to the store")
    func canvasCrud() {
        let store = tempStore()
        let created = store.createCanvas(title: "Iran 2026-08-20")
        #expect(store.canvases.contains(where: { $0.id == created.id }))
        store.openCanvas(id: created.id)
        #expect(store.canvasOpen)
        #expect(store.activeCanvas()?.title == "Iran 2026-08-20")
        store.deleteCanvas(id: created.id)
        #expect(store.canvases.isEmpty)
    }

    @Test("opening canvas after a screenshot places the jpeg")
    func canvasOpenPlacesScreenshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        let bot = store.createBot(name: "Cam", title: "cam")
        let userId = try #require(store.session?.userId)
        let userDir = AccountLayout.userDirectory(global: dir, userId: userId)
        let home = try BotHomeStore(root: userDir).homeURL(botId: bot.id)
        let shotDir = home.appendingPathComponent(".computer", isDirectory: true)
        try FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        let jpeg = try #require(Self.testJPEG())
        try jpeg.write(to: shotDir.appendingPathComponent("screen.jpg"))
        store.openCanvas(id: nil, placingScreenshotFrom: bot.id)
        let opened = try #require(store.activeCanvas())
        #expect(!opened.images.isEmpty)
        #expect(store.canvasOpen)
    }

    @Test("folder watcher save lists persist and run now sends")
    func folderWatcherSaveListAndRun() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dataDir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.signUp(name: "A", email: "watch@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "watcher")
        let inbox = dataDir.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        var watcher = FolderWatcherRecord.makeNew()
        watcher.name = "Inbox"
        watcher.watchPath = inbox.path
        watcher.instructions = "Summarize new files"
        watcher.botId = bot.id
        try store.saveFolderWatcher(watcher)

        #expect(store.folderWatchers.contains(where: { $0.id == watcher.id && $0.name == "Inbox" }))
        #expect(throws: FolderWatcherError.emptyPath) {
            var empty = FolderWatcherRecord.makeNew()
            empty.name = "No path"
            try store.saveFolderWatcher(empty)
        }

        let reloaded = AppStore(dataDirectory: dataDir, delayScale: 0.01)
        reloaded.pluginClient = AlwaysAllowPlugins()
        #expect(reloaded.folderWatchers.contains(where: { $0.id == watcher.id && $0.name == "Inbox" }))

        let result = store.runFolderWatcherNow(id: watcher.id)
        #expect(result.contains("Triggered"))
        #expect(store.messages(for: bot.id).contains(where: {
            $0.role == .user
                && $0.firstText.contains("Inbox")
                && $0.firstText.contains("SKILL.md")
                && $0.firstText.contains("move_file")
        }))
        #expect(store.folderWatchers.first(where: { $0.id == watcher.id })?.lastTriggeredAt != nil)

        try store.deleteFolderWatcher(id: watcher.id)
        #expect(!store.folderWatchers.contains(where: { $0.id == watcher.id }))
    }

    @Test("folder watcher does not start a second run while the bot is busy")
    func folderWatcherSkipsWhileBusy() {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "watchbusy@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "watcher")
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyWatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var watcher = FolderWatcherRecord.makeNew()
        watcher.name = "Inbox"
        watcher.watchPath = inbox.path
        watcher.botId = bot.id
        try? store.saveFolderWatcher(watcher)

        let first = store.runFolderWatcherNow(id: watcher.id)
        let second = store.runFolderWatcherNow(id: watcher.id)
        let echo = store.handleFolderWatcherEvent(
            id: watcher.id,
            changedPaths: [inbox.appendingPathComponent("Applications/a.dmg").path]
        )
        #expect(first.contains("Triggered"))
        #expect(second.contains("Skipped"))
        #expect(echo.contains("Skipped"))
        #expect(store.messages(for: bot.id).filter { $0.role == .user }.count == 1)
    }

    @Test("automatic watcher echoes stay skipped after the run until cooldown ends")
    func folderWatcherSkipsEchoAfterRun() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "watchecho@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "watcher")
        store.chatCompleter = QueueChatClient([ChatCompletionResponse(text: "organized")])
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyWatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var watcher = FolderWatcherRecord.makeNew()
        watcher.name = "Inbox"
        watcher.watchPath = inbox.path
        watcher.botId = bot.id
        try? store.saveFolderWatcher(watcher)

        #expect(store.runFolderWatcherNow(id: watcher.id).contains("Triggered"))
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let echo = store.handleFolderWatcherEvent(
            id: watcher.id,
            changedPaths: [
                inbox.appendingPathComponent("a.dmg").path,
                inbox.appendingPathComponent("Applications/a.dmg").path,
            ]
        )
        #expect(echo.contains("Skipped"))
        let manual = store.runFolderWatcherNow(id: watcher.id)
        #expect(manual.contains("Triggered"))
        #expect(store.messages(for: bot.id).filter { $0.role == .user }.count == 2)
    }

    @Test("bot text and cards already have a copy control; user text does not")
    func inlineCopyControl() {
        let botCard = ThreadMessage(
            id: "1",
            threadId: "t",
            seq: 1,
            role: .bot,
            blocks: [.card(lines: [CardLine(k: "mcp", v: "list")])]
        )
        let botText = ThreadMessage(
            id: "2",
            threadId: "t",
            seq: 2,
            role: .bot,
            blocks: [.text("listed the folder")]
        )
        let userText = ThreadMessage(
            id: "3",
            threadId: "t",
            seq: 3,
            role: .user,
            blocks: [.text("clean downloads")]
        )
        #expect(botCard.hasInlineCopyControl)
        #expect(botText.hasInlineCopyControl)
        #expect(!userText.hasInlineCopyControl)
    }

    @Test("folder watcher prompt names the watch path and blocks skill authoring")
    func folderWatcherPromptRules() {
        var watcher = FolderWatcherRecord.makeNew()
        watcher.name = "Folder-Organize"
        watcher.watchPath = "/Volumes/Storage/Downloads"
        watcher.instructions = "paste these into Skills as SKILL.md"
        let msg = FolderWatcherPromptBuilder.userMessage(
            watcher: watcher,
            changedPaths: [],
            manual: true
        )
        #expect(msg.contains("/Volumes/Storage/Downloads"))
        #expect(msg.contains("SKILL.md"))
        #expect(msg.contains("move_file"))
        #expect(msg.contains("one organize pass"))
        #expect(msg.contains("whichever bot"))
        #expect(msg.contains("browser skill"))
        #expect(msg.contains("Instructions:"))
        #expect(msg.contains("paste these into Skills as SKILL.md"))
    }

    private static func testJPEG() -> Data? {
        let context = CGContext(
            data: nil,
            width: 32,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
