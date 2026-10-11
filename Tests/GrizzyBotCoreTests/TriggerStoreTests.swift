import Foundation
import GrizzyBotCore
import Testing

@Suite("Routine triggers in the store")
@MainActor
struct TriggerStoreTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        return store
    }

    private func finished(_ store: AppStore, _ botId: String) async {
        for _ in 0..<300 {
            if let status = store.threads[botId]?.run?.status, status != .running { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("webhook: wrong secret refused, right secret starts the run with the payload as data, rapid repeat throttled")
    func webhookFlow() async {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let client = QueueChatClient([ChatCompletionResponse(text: "triaged")])
        store.chatCompleter = client
        let routine = store.createRoutine(botId: bot.id, name: "CI", prompt: "Triage this event.", cron: "")
        #expect(!routine.hasSchedule)
        #expect(store.handleWebhook(routineId: routine.id, secret: "x", payload: nil).status == 401)

        let secret = store.enableWebhook(routineId: routine.id)
        #expect(secret?.count == 64)
        #expect(store.handleWebhook(routineId: routine.id, secret: "wrong", payload: "p").status == 401)
        #expect(store.handleWebhook(routineId: "nope", secret: secret, payload: "p").status == 401)

        let ok = store.handleWebhook(routineId: routine.id, secret: secret, payload: "{\"build\":\"red\"}")
        #expect(ok.status == 202)
        #expect(store.handleWebhook(routineId: routine.id, secret: secret, payload: "again").status == 429)
        await finished(store, bot.id)
        let prompt = client.requests.first?.messages.last(where: { $0.role == "user" })?.content ?? ""
        #expect(prompt.contains("{\"build\":\"red\"}"))
        #expect(prompt.contains("untrusted"))
        let notes = (store.threads[bot.id]?.messages ?? []).flatMap(\.blocks).compactMap { block -> String? in
            if case .meta(let text) = block { return text }
            return nil
        }
        #expect(notes.contains { $0.contains("fired by webhook") })
        // The schedule is untouched: still event-only.
        #expect(store.routines(for: bot.id).first?.nextRunAt == .distantFuture)
    }

    @Test("disabling a webhook revokes the secret")
    func revoke() {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let routine = store.createRoutine(botId: bot.id, name: "CI", prompt: "x", cron: "")
        let secret = store.enableWebhook(routineId: routine.id)
        let rotated = store.rotateWebhookSecret(routineId: routine.id)
        #expect(rotated != secret)
        #expect(store.handleWebhook(routineId: routine.id, secret: secret, payload: nil).status == 401)
        store.disableWebhook(routineId: routine.id)
        #expect(store.handleWebhook(routineId: routine.id, secret: rotated, payload: nil).status == 401)
    }

    @Test("heartbeat: an all-clear leaves no message, a real finding does")
    func heartbeat() async {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(text: "HEARTBEAT_OK"),
            ChatCompletionResponse(text: "The deploy is stuck."),
        ])
        let hb = store.createHeartbeat(botId: bot.id, checklist: "- deploys", everyMinutes: 30)
        #expect(hb?.cron == "*/30 * * * *")
        store.runRoutine(hb!.id)
        await finished(store, bot.id)
        let botMessagesAfterQuiet = store.threads[bot.id]?.messages.filter { $0.role == .bot } ?? []
        #expect(botMessagesAfterQuiet.isEmpty)
        #expect(store.threads[bot.id]?.run?.status == .completed)

        store.runRoutine(hb!.id)
        for _ in 0..<300 {
            if store.threads[bot.id]?.messages.contains(where: { $0.firstText.contains("deploy is stuck") }) == true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.threads[bot.id]?.messages.contains { $0.firstText.contains("deploy is stuck") } == true)
    }

    @Test("continuity: the second run sees the first run's report")
    func continuity() async {
        let store = makeStore()
        let bot = store.createBot(name: "Ada", title: "")
        let client = QueueChatClient([
            ChatCompletionResponse(text: "Report one: three new items."),
            ChatCompletionResponse(text: "Report two."),
        ])
        store.chatCompleter = client
        let routine = store.createRoutine(botId: bot.id, name: "Digest", prompt: "Summarise news.", cron: "0 9 * * *")
        store.setRoutineOptions(routine.id, continuity: true)
        store.runRoutine(routine.id)
        await finished(store, bot.id)
        #expect(store.routines(for: bot.id).first?.lastOutput?.contains("three new items") == true)
        store.runRoutine(routine.id)
        for _ in 0..<300 where client.requests.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        let second = client.requests.last?.messages.last(where: { $0.role == "user" })?.content ?? ""
        #expect(second.contains("three new items"))
    }

    @Test("heartbeat cron helper")
    func cron() {
        #expect(AppStore.heartbeatCron(everyMinutes: 1) == "*/5 * * * *")
        #expect(AppStore.heartbeatCron(everyMinutes: 15) == "*/15 * * * *")
        #expect(AppStore.heartbeatCron(everyMinutes: 120) == "0 */2 * * *")
    }
}
