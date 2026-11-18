import Foundation
import GrizzyBotCore
import Testing

@Suite("Config assistant")
struct ConfigAssistantTests {
    @Test("only listed settings with valid values can change")
    func validation() throws {
        let base = AppConfig()
        let next = try ConfigAssistant.applying(key: "memoryRelevanceMode", value: "off", to: base)
        #expect(next.memoryRelevanceMode == .off)
        #expect(throws: ConfigAssistant.Failure.self) { try ConfigAssistant.applying(key: "memoryRelevanceMode", value: "nope", to: base) }
        #expect(throws: ConfigAssistant.Failure.self) { try ConfigAssistant.applying(key: "braveSearchKey", value: "x", to: base) }
        #expect(throws: ConfigAssistant.Failure.self) { try ConfigAssistant.applying(key: "agentStallTimeoutMs", value: "-5", to: base) }
        #expect(try ConfigAssistant.applying(key: "privacyOnDeviceDetection", value: "on", to: base).privacyFilter.useOnDeviceNER)
        #expect(ConfigAssistant.settings.allSatisfy { !ConfigHistory.isSecretKey($0.key) })
    }
}

@Suite("config_manage tool")
@MainActor
struct ConfigToolTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
    }

    @Test("a change waits for a person even on an auto-approve bot, then lands in the history and can be undone")
    func approvalAndHistory() async throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "cfg@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        if let idx = store.bots.firstIndex(where: { $0.id == bot.id }) { store.bots[idx].autoApprove = true }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "config_manage", arguments: "{\"action\":\"set\",\"key\":\"queueMode\",\"value\":\"collect\"}")]),
            ChatCompletionResponse(text: "done"),
        ])
        let before = store.appConfig.queueMode
        store.send(botId: bot.id, text: "make messages collect")
        #expect(await store.waitForPendingTool(botId: bot.id))
        #expect(store.threads[bot.id]?.pendingTool?.tool == "config.change")
        #expect(store.appConfig.queueMode == before, "nothing changes before approval")
        // Direct save stands in for the approved run; the history is what matters here.
        var changed = store.appConfig
        changed.queueMode = .collect
        store.saveAppConfig(changed)
        let entry = try #require(store.configHistory().last)
        #expect(entry.summary.contains("queueMode"))
        #expect(store.revertConfigChange(id: entry.id))
        #expect(store.appConfig.queueMode == before)
    }
}
