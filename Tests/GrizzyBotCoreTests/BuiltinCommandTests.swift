import Foundation
import GrizzyBotCore
import Testing

@Suite("Built-in commands")
@MainActor
struct BuiltinCommandTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        return store
    }

    private func lastReply(_ store: AppStore, _ botId: String) -> String {
        store.threads[botId]?.messages.last(where: { $0.role == .bot })?.firstText ?? ""
    }

    @Test("resolution: skills win over built-ins, built-ins win over unknown")
    func resolution() {
        #expect(SlashCommand.resolve("/context", skills: []) == .builtin(.context, argument: ""))
        #expect(SlashCommand.resolve("/goal ship it", skills: []) == .builtin(.goal, argument: "ship it"))
        #expect(SlashCommand.resolve("/nonsense", skills: []) == .unknown("nonsense"))
        let helpText = SlashCommand.helpText(skills: [])
        #expect(helpText.contains("/context") && helpText.contains("/goal"))
    }

    @Test("/context reports without calling the model")
    func context() {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let client = QueueChatClient([])
        store.chatCompleter = client
        store.send(botId: bot.id, text: "/context")
        let reply = lastReply(store, bot.id)
        #expect(reply.contains("Context"))
        #expect(reply.contains("System prompt"))
        #expect(reply.contains("Free"))
        #expect(client.requests.isEmpty)
    }

    @Test("breakdown arithmetic and rendering")
    func breakdown() {
        let b = ContextBreakdown(entries: [.init(label: "A", chars: 4_000), .init(label: "B", chars: 0)], windowChars: 40_000)
        #expect(b.usedChars == 4_000)
        let text = b.render()
        #expect(text.contains("A: 1.0k (10%)"))
        #expect(!text.contains("B:"))
        let full = ContextBreakdown(entries: [.init(label: "A", chars: 39_000)], windowChars: 40_000).render()
        #expect(full.contains("/compact"))
    }

    @Test("/goal sets, shows and clears, and the goal reaches the system prompt")
    func goal() async {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let client = QueueChatClient([ChatCompletionResponse(text: "On it.")])
        store.chatCompleter = client
        store.send(botId: bot.id, text: "/goal")
        #expect(lastReply(store, bot.id).contains("No standing goal"))

        store.send(botId: bot.id, text: "/goal get the tests green")
        for _ in 0..<300 where client.requests.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.bots.first(where: { $0.id == bot.id })?.goal == "get the tests green")
        let system = client.requests.first?.messages.first(where: { $0.role == "system" })?.content ?? ""
        #expect(system.contains("Standing goal"))
        #expect(system.contains("get the tests green"))

        for _ in 0..<300 {
            if store.threads[bot.id]?.run?.status == .completed { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        store.send(botId: bot.id, text: "/goal clear")
        #expect(store.bots.first(where: { $0.id == bot.id })?.goal == nil)
        #expect(lastReply(store, bot.id).contains("cleared"))
    }

    @Test("/plan with a task asks the model to plan, not act")
    func plan() async {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let client = QueueChatClient([ChatCompletionResponse(text: "1. do it")])
        store.chatCompleter = client
        store.send(botId: bot.id, text: "/plan migrate the database")
        for _ in 0..<300 where client.requests.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        let prompt = client.requests.first?.messages.last(where: { $0.role == "user" })?.content ?? ""
        #expect(prompt.contains("Do NOT carry it out"))
        #expect(prompt.contains("migrate the database"))
        store.send(botId: bot.id, text: "/plan")
        #expect(lastReply(store, bot.id).contains("Usage"))
    }

    @Test("/usage and /compact answer locally on a fresh bot")
    func usageAndCompact() {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        store.send(botId: bot.id, text: "/usage")
        #expect(lastReply(store, bot.id).contains("No usage"))
        store.send(botId: bot.id, text: "/compact")
        #expect(lastReply(store, bot.id).contains("Nothing to compact"))
    }
}
