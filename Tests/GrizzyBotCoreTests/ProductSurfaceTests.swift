import Foundation
import GrizzyBotCore
import Testing

@Suite("Chat search")
struct ChatSearchTests {
    @Test("finds a message across bots and ignores short queries")
    func searchAllBots() {
        let alice = Bot(id: "a", name: "Alice", color: "#3EC5A8", threadId: "ta")
        let bob = Bot(id: "b", name: "Bob", color: "#F5A03C", threadId: "tb")
        var threadA = ThreadData(threadId: "ta")
        threadA.messages = [
            ThreadMessage(id: "m1", threadId: "ta", seq: 1, role: .user, blocks: [.text("vault backup plan")]),
        ]
        var threadB = ThreadData(threadId: "tb")
        threadB.messages = [
            ThreadMessage(id: "m2", threadId: "tb", seq: 1, role: .bot, blocks: [.text("the shell is disabled")]),
        ]
        let all = ChatSearch.hits(
            query: "vault",
            bots: [alice, bob],
            groups: [],
            threads: ["a": threadA, "b": threadB],
            scope: .all
        )
        #expect(all.map(\.messageId) == ["m1"])
        #expect(all.first?.botName == "Alice")

        let scoped = ChatSearch.hits(
            query: "shell",
            bots: [alice, bob],
            groups: [],
            threads: ["a": threadA, "b": threadB],
            scope: .thread("b")
        )
        #expect(scoped.map(\.messageId) == ["m2"])
        #expect(ChatSearch.hits(query: "v", bots: [alice], groups: [], threads: ["a": threadA], scope: .all).isEmpty)
    }
}

@Suite("Paste guard")
struct PasteGuardTests {
    @Test("warns on vault-shaped dumps and huge pastes")
    func vaultDump() {
        #expect(PasteGuard.warning(for: "hello") == nil)
        let wiki = (0..<12).map { "[[Note \($0)]]" }.joined(separator: "\n")
        #expect(PasteGuard.warning(for: wiki) != nil)
        let huge = String(repeating: "x", count: 9_000)
        #expect(PasteGuard.warning(for: huge) != nil)
        let local = String(repeating: "y", count: 6_500)
        #expect(PasteGuard.warning(for: local, localModel: true) != nil)
        #expect(PasteGuard.warning(for: local, localModel: false) == nil)
    }
}

@Suite("Composer Return")
struct ComposerKeysTests {
    @Test("Return sends non-empty text; Shift-Return and empty do not")
    func sendPolicy() {
        #expect(ComposerKeys.shouldSend(shiftHeld: false, text: "hi"))
        #expect(!ComposerKeys.shouldSend(shiftHeld: true, text: "hi"))
        #expect(!ComposerKeys.shouldSend(shiftHeld: false, text: "  "))
    }
}

@Suite("Plugin catalog filter")
struct PluginCatalogFilterTests {
    @Test("matches name slug and blurb")
    func filter() {
        let gmail = ConnectionItem(slug: "gmail", name: "Gmail", blurb: "Read mail")
        let slack = ConnectionItem(slug: "slack", name: "Slack", blurb: "Chat")
        #expect(PluginCatalogFilter.filter([gmail, slack], query: "mail") == [gmail])
        #expect(PluginCatalogFilter.filter([gmail, slack], query: "").count == 2)
    }
}

@Suite("Secrets")
struct SecretFieldTests {
    @Test("empty input keeps the stored key; clear wipes it")
    func keepAndClear() {
        #expect(SecretFieldUpdate.applying(current: "kept", input: "") == "kept")
        #expect(SecretFieldUpdate.applying(current: "kept", input: " new ") == "new")
        var config = AppConfig(composioConnectKey: "c", boxToken: "b", ttsKey: "t")
        config.applySecret(.composioConnect, input: "")
        #expect(config.composioConnectKey == "c")
        config.clearSecret(.composioConnect)
        #expect(config.composioConnectKey == nil)
        config.applySecret(.tts, input: "eleven")
        #expect(config.ttsKey == "eleven")
        #expect(config.boxConfigured)
        config.clearSecret(.box)
        #expect(!config.boxConfigured)
        config.applySecret(.sentry, input: "https://key@o0.ingest.sentry.io/1")
        #expect(config.sentryConfigured)
        config.clearSecret(.sentry)
        #expect(!config.sentryConfigured)
    }
}

@Suite("Bot capabilities")
struct BotCapabilityTests {
    @Test("banner explains missing shell and computer")
    func banner() {
        var bot = Bot(id: "b", name: "Scout", color: "#3EC5A8", threadId: "t", enabledTools: AgentToolCatalog.allIds)
        #expect(BotCapabilitySummary.of(bot).banner == nil)
        bot.setTool("shell", enabled: false)
        #expect(BotCapabilitySummary.of(bot).banner?.contains("Shell") == true)
        bot.setTool("computer_screenshot", enabled: false)
        bot.setTool("request_takeover", enabled: false)
        for id in AgentToolCatalog.allIds where id.hasPrefix("computer_") {
            bot.setTool(id, enabled: false)
        }
        let both = BotCapabilitySummary.of(bot).banner
        #expect(both?.contains("Shell") == true)
        #expect(both?.contains("Computer") == true)
    }

    @Test("workspace default is distinct from a catalog model")
    func modelChoice() {
        var bot = Bot(id: "b", name: "Scout", color: "#3EC5A8", threadId: "t")
        #expect(BotModelChoice.current(bot: bot) == .workspaceDefault)
        bot.modelProvider = "openrouter"
        bot.modelId = ModelCatalog.defaultModelId
        if case .catalog(let provider, let id, _) = BotModelChoice.current(bot: bot) {
            #expect(provider == "openrouter")
            #expect(id == ModelCatalog.defaultModelId)
        } else {
            Issue.record("expected catalog choice")
        }
        #expect(!ModelCatalog.deviceCodeProviders.isEmpty)
        #expect(ModelCatalog.deviceCodeProviders.allSatisfy { $0.signIn == .deviceCode })
    }

    @Test("composer choices include fetched LAN models and show the active name")
    func composerChoicesIncludeFetched() {
        var bot = Bot(id: "b", name: "Scout", color: "#3EC5A8", threadId: "t")
        let fetched = [LocalModelRef(id: "qwen3-coder-next-mlx", label: "Qwen3 Coder")]
        let choices = BotModelChoice.choices(
            workspaceProvider: "lmstudio",
            workspaceModel: "qwen3-coder-next-mlx",
            fetched: fetched
        )
        #expect(choices.contains(.workspaceDefault))
        #expect(choices.contains(where: {
            if case .catalog("lmstudio", "qwen3-coder-next-mlx", _) = $0 { return true }
            return false
        }))
        #expect(BotModelChoice.activeLabel(bot: bot, workspaceModel: "qwen3-coder-next-mlx") == "qwen3-coder-next-mlx")
        bot.modelProvider = "lmstudio"
        bot.modelId = "qwen3-coder-next-mlx"
        #expect(BotModelChoice.activeLabel(bot: bot, workspaceModel: "other") == "qwen3-coder-next-mlx")
    }

    @Test("composer lists models from every enabled provider and skips disabled ones")
    func composerChoicesFromEnabledProviders() {
        let choices = BotModelChoice.choices(
            workspaceProvider: "lmstudio",
            workspaceModel: "qwen-local",
            enabledProviders: [
                EnabledProviderModels(
                    provider: "lmstudio",
                    providerName: "LM Studio",
                    fetched: [LocalModelRef(id: "qwen-local", label: "Qwen Local")]
                ),
                EnabledProviderModels(
                    provider: "openai-compatible",
                    providerName: "OpenAI Compatible",
                    fetched: [LocalModelRef(id: "gpt-oss", label: "GPT OSS")]
                ),
            ]
        )
        #expect(choices.contains(where: {
            if case .catalog("lmstudio", "qwen-local", _) = $0 { return true }
            return false
        }))
        #expect(choices.contains(where: {
            if case .catalog("openai-compatible", "gpt-oss", _) = $0 { return true }
            return false
        }))
        #expect(!choices.contains(where: {
            if case .catalog("openrouter", _, _) = $0 { return true }
            return false
        }))
    }
}

@Suite("Run log")
struct RunLogTests {
    @Test("caps length and dumps readable text")
    func capAndDump() {
        var lines: [RunLogLine] = []
        for i in 0..<RunLog.maxLines + 5 {
            lines = RunLog.appending(lines, botId: "b", kind: "tool", text: "step \(i)")
        }
        #expect(lines.count == RunLog.maxLines)
        let dump = RunLog.dump(lines)
        #expect(dump.contains("tool b:"))
        #expect(!RunLog.dump([]).isEmpty)
    }
}

@Suite("Workspace backup")
struct WorkspaceBackupTests {
    @Test("uses iCloud Drive when the CloudDocs folder exists")
    func iCloudPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-home-\(UUID().uuidString)")
        let cloud = root
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        #expect(WorkspaceBackup.iCloudDriveURL(fileManager: .default, home: root) == cloud)
        let dir = WorkspaceBackup.backupDirectory(fileManager: .default, home: root, resolveUbiquity: false)
        #expect(dir.lastPathComponent == "GrizzyBot Backups")
        #expect(WorkspaceBackup.filename().hasPrefix("grizzybot-backup-"))
        #expect(WorkspaceBackup.iCloudDriveURL(fileManager: .default, home: FileManager.default.temporaryDirectory) == nil)
    }

    @Test("prefers the iCloud ubiquity container over CloudDocs")
    func ubiquityContainerWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-home-\(UUID().uuidString)")
        let cloud = root
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("gb-ubiq-\(UUID().uuidString)")
        let dir = WorkspaceBackup.backupDirectory(
            fileManager: .default,
            home: root,
            ubiquityContainer: container,
            resolveUbiquity: false
        )
        #expect(dir.path.contains("Documents/Backups") || dir.path.hasSuffix("Documents/Backups"))
        #expect(dir.path.hasPrefix(container.path))
        #expect(WorkspaceBackup.ubiquityContainerIdentifier == "iCloud.com.grizzybot.app")
    }
}

@Suite("ElevenLabs")
struct ElevenLabsTests {
    @Test("builds a signed request for a named voice")
    func request() throws {
        #expect(ElevenLabsTTS.voiceId(named: "Rachel") == ElevenLabsTTS.defaultVoiceId)
        #expect(ElevenLabsTTS.voiceId(named: "Adam") == "pNInz6obpgDQGcFmaJgB")
        let request = try ElevenLabsTTS.request(text: "hello", apiKey: "sk-test", voiceName: "Rachel")
        #expect(request.url?.path.contains(ElevenLabsTTS.defaultVoiceId) == true)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "sk-test")
        #expect(throws: ElevenLabsError.self) {
            try ElevenLabsTTS.request(text: "hello", apiKey: "  ", voiceName: nil)
        }
    }
}

@Suite("Context compaction of huge user pastes")
struct HugePromptCompactionTests {
    @Test("shrinks a stuffed first user message")
    func compactUserDump() {
        let dump = String(repeating: "[[Note]]\n", count: 4_000)
        let messages = [
            ChatMessage.system("sys"),
            ChatMessage(role: "user", content: dump),
        ]
        let packed = ContextCompactor.compact(messages, budget: 8_000)
        #expect(packed.compacted)
        #expect(ContextCompactor.encodedSize(packed.messages) < ContextCompactor.encodedSize(messages))
        #expect((packed.messages.last?.content?.count ?? 0) < dump.count)
    }
}

@MainActor
@Suite("Store product surface")
struct StoreProductSurfaceTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return store
    }

    @Test("per-bot model, undo send, edit, branch, regenerate, keys, backup, diagnostics")
    func storeSurface() async throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "surf@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Scout", title: "helper")
        store.patchBot(bot.id, modelProvider: "openrouter", modelId: ModelCatalog.defaultModelId)
        #expect(store.bots.first?.modelId == ModelCatalog.defaultModelId)

        store.send(botId: bot.id, text: "hello there")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(store.messages(for: bot.id).contains(where: { $0.role == .user }))
        let restored = store.undoSend(botId: bot.id)
        #expect(restored == "hello there")
        #expect(store.messages(for: bot.id).isEmpty)

        store.send(botId: bot.id, text: "first")
        try? await Task.sleep(for: .milliseconds(400))
        store.send(botId: bot.id, text: "second")
        try? await Task.sleep(for: .milliseconds(400))
        let userIds = store.messages(for: bot.id).filter { $0.role == .user }.map(\.id)
        #expect(userIds.count == 2)
        store.editUserMessage(botId: bot.id, messageId: userIds[0], text: "first-edited")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(store.messages(for: bot.id).filter { $0.role == .user }.count == 1)
        #expect(store.messages(for: bot.id).first?.firstText == "first-edited")

        let userId = try #require(store.messages(for: bot.id).first(where: { $0.role == .user })?.id)
        let branch = store.branchFromMessage(botId: bot.id, messageId: userId)
        #expect(branch != nil)
        #expect(store.bots.first?.tasks.isEmpty == false)

        store.regenerateLast(botId: bot.id)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(store.messages(for: bot.id).contains(where: { $0.role == .bot }))

        var config = store.appConfig
        config.composioConnectKey = "connect"
        config.ttsKey = "tts"
        store.saveAppConfig(config)
        store.clearSecret(.composioConnect)
        #expect(store.appConfig.composioConnectKey == nil)
        #expect(store.appConfig.ttsKey == "tts")
        store.clearSecret(.tts)
        #expect(!store.appConfig.ttsConfigured)

        store.appendRunLog(botId: bot.id, kind: "mcp", text: "stderr: closed stdout")
        #expect(store.lastRunLogText().contains("closed stdout"))

        let data = try #require(store.exportWorkspaceJSON())
        #expect(store.importWorkspaceJSON(data))
        let url = try #require(store.writeWorkspaceBackup(to: FileManager.default.temporaryDirectory))
        #expect(FileManager.default.fileExists(atPath: url.path))

        #expect(AgentLoopRequest.charBudget(provider: "ollama") < AgentLoopRequest.charBudget(provider: "openrouter"))
    }

    @Test("UI-test harness opens the shell even with an empty workspace")
    func uiTestHarness() {
        let store = tempStore()
        #expect(store.route != .shell || store.bots.isEmpty)
        store.prepareUITestWorkspace()
        #expect(store.route == .shell)
        #expect(!store.bots.isEmpty)
        #expect(!store.showHostPrompt)
    }
}
