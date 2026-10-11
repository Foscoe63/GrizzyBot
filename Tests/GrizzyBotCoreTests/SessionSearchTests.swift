import Foundation
import GrizzyBotCore
import Testing

@Suite("Session search")
@MainActor
struct SessionSearchTests {
    @Test("ranks the relevant message first and carries the date")
    func ranking() {
        let now = Date()
        let docs = [
            SessionSearch.Doc(thread: "main chat", role: .user, date: now.addingTimeInterval(-86_400 * 40), text: "Let's price the pro plan at $29 a month."),
            SessionSearch.Doc(thread: "main chat", role: .bot, date: now.addingTimeInterval(-86_400 * 2), text: "Lunch options near the office."),
            SessionSearch.Doc(thread: "task “launch”", role: .bot, date: now, text: "Decision: pricing page ships Friday with the pro plan at $29."),
        ]
        let hits = SessionSearch.search(docs: docs, query: "pricing plan", now: now)
        #expect(hits.count == 2)
        #expect(hits.first?.thread == "task “launch”")
        #expect(SessionSearch.render(hits).contains("[20"))
        #expect(SessionSearch.search(docs: docs, query: "zebra", now: now).isEmpty)
        #expect(SessionSearch.search(docs: [], query: "plan").isEmpty)
    }

    @Test("long messages are cut around the match")
    func snippet() {
        let long = String(repeating: "filler words here ", count: 80) + "the secret codename is Bluebird. " + String(repeating: "more filler ", count: 80)
        let hit = SessionSearch.search(docs: [.init(thread: "t", role: .user, date: .now, text: long)], query: "bluebird").first
        #expect(hit?.snippet.contains("Bluebird") == true)
        #expect((hit?.snippet.count ?? 999) < 340)
    }

    @Test("the tool searches this bot's chats only")
    func scopedToTheBot() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        let ada = store.createBot(name: "Ada", title: "")
        let grace = store.createBot(name: "Grace", title: "")
        store.chatCompleter = QueueChatClient([ChatCompletionResponse(text: "Noted the codename Bluebird.")])
        store.send(botId: ada.id, text: "Our codename is Bluebird")
        for _ in 0..<300 {
            if store.threads[ada.id]?.run?.status == .completed { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let adaHits = SessionSearch.search(docs: store.sessionDocs(for: ada.id), query: "bluebird")
        let graceHits = SessionSearch.search(docs: store.sessionDocs(for: grace.id), query: "bluebird")
        #expect(!adaHits.isEmpty)
        #expect(graceHits.isEmpty)
        let tools = AgentToolCatalog.chatTools(enabledIds: ["search_memory", "remember"])
        #expect(tools.contains { $0.function.name == "search_sessions" })
        #expect(!AgentToolCatalog.chatTools(enabledIds: ["web_search"]).contains { $0.function.name == "search_sessions" })
    }
}
