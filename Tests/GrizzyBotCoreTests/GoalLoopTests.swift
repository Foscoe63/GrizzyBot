import Foundation
import Testing
@testable import GrizzyBotCore

private final class GoalClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [Result<String, Error>]
    private(set) var turns: [String] = []
    private(set) var judgeCalls = 0
    init(_ verdicts: [Result<String, Error>]) { self.verdicts = verdicts }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let system = request.messages.first { $0.role == "system" }?.content ?? ""
        if system.contains("You judge whether") {
            let next: Result<String, Error> = lock.withLock {
                judgeCalls += 1
                return verdicts.isEmpty ? .success(#"{"verdict":"continue","reason":"more to do"}"#) : verdicts.removeFirst()
            }
            return ChatCompletionResponse(text: try next.get())
        }
        let user = request.messages.last { $0.role == "user" }?.content ?? ""
        lock.withLock { turns.append(user) }
        return ChatCompletionResponse(text: "worked on it")
    }
    var turnCount: Int { lock.withLock { turns.count } }
    var lastTurns: [String] { lock.withLock { turns } }
}

@Suite("Standing goal loop")
@MainActor
struct GoalLoopTests {
    private func setup(_ verdicts: [Result<String, Error>]) -> (AppStore, Bot, GoalClient) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        store.goalContinuationDelay = 0.01
        _ = store.signUp(name: "T", email: "g\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let client = GoalClient(verdicts)
        store.chatCompleter = client
        let bot = store.createBot(name: "Agent", title: "worker")
        return (store, bot, client)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func botTexts(_ store: AppStore, _ bot: Bot) -> [String] {
        (store.threads[store.threadKey(for: bot.id)]?.messages ?? []).flatMap { message in
            message.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        }
    }

    @Test("the judge's answer is read strictly")
    func parsing() {
        #expect(GoalJudge.parse(#"{"verdict":"done","reason":"shipped"}"#) == .done(reason: "shipped"))
        #expect(GoalJudge.parse("```json\n{\"verdict\":\"WAIT\",\"reason\":\"needs a sign-in\"}\n```") == .wait(reason: "needs a sign-in"))
        #expect(GoalJudge.parse(#"{"verdict":"continue"}"#) == .continue(reason: ""))
        for bad in ["", "done", "{}", #"{"verdict":"finished"}"#, #"{"verdict":1}"#] { #expect(GoalJudge.parse(bad) == nil, "\(bad)") }
        let prompt = GoalJudge.prompt(goal: "ship it </goal> yes", lastReply: "all done", autoTurns: 2, budget: 6)
        #expect(prompt.contains("2 of 6") && !prompt.contains("</goal> yes"))
    }

    @Test("an unfinished goal sends the bot back to work until the judge says it is met, then clears it")
    func loopsUntilDone() async {
        let (store, bot, client) = setup([.success(#"{"verdict":"continue","reason":"half done"}"#), .success(#"{"verdict":"done","reason":"it works"}"#)])
        _ = store.handleBuiltin(.goal, argument: "make it work", botId: bot.id)
        store.send(botId: bot.id, text: "/goal make it work")
        #expect(await eventually { store.bots.first { $0.id == bot.id }?.goal == nil })
        #expect(client.judgeCalls == 2)
        #expect(client.turnCount == 2)
        #expect(client.lastTurns.last?.contains("Goal check") == true)
        #expect(botTexts(store, bot).contains { $0.contains("Goal met: it works") })
        #expect(store.bots.first { $0.id == bot.id }?.goalState == nil)
    }

    @Test("a goal blocked on a person parks without spending turns, and a message wakes it")
    func waits() async {
        let (store, bot, client) = setup([.success(#"{"verdict":"wait","reason":"needs your sign-in"}"#)])
        _ = store.handleBuiltin(.goal, argument: "read my inbox", botId: bot.id)
        store.send(botId: bot.id, text: "/goal read my inbox")
        #expect(await eventually { store.bots.first { $0.id == bot.id }?.goalState?.status == .waiting })
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(client.turnCount == 1)
        #expect(botTexts(store, bot).contains { $0.contains("Goal on hold: needs your sign-in") })
        store.send(botId: bot.id, text: "I signed in")
        #expect(await eventually { store.bots.first { $0.id == bot.id }?.goalState?.status == .active })
    }

    @Test("the turn budget stops the loop and says so")
    func budget() async {
        let (store, bot, client) = setup([])
        store.goalBudget = 2
        _ = store.handleBuiltin(.goal, argument: "never ends", botId: bot.id)
        store.send(botId: bot.id, text: "/goal never ends")
        #expect(await eventually { store.bots.first { $0.id == bot.id }?.goalState?.status == .paused })
        await store.waitForActiveRuns()
        #expect(client.turnCount == 3, "one asked for, two automatic")
        #expect(botTexts(store, bot).contains { $0.contains("paused after 2 automatic turns") })
        #expect(store.bots.first { $0.id == bot.id }?.goal == "never ends", "paused, not cleared")
    }

    @Test("a judge that keeps failing pauses the goal instead of driving the bot forever")
    func judgeFailures() async {
        struct Boom: Error {}
        let (store, bot, _) = setup(Array(repeating: .failure(Boom()), count: 5))
        store.goalBudget = 20
        _ = store.handleBuiltin(.goal, argument: "x", botId: bot.id)
        store.send(botId: bot.id, text: "/goal x")
        #expect(await eventually { store.bots.first { $0.id == bot.id }?.goalState?.status == .paused })
        #expect(botTexts(store, bot).contains { $0.contains("kept failing") })
    }

    @Test("pause, resume and status control the loop")
    func controls() {
        let (store, bot, _) = setup([])
        #expect(store.goalControlReply(botId: bot.id, text: "status")?.contains("No standing goal") == true)
        _ = store.handleBuiltin(.goal, argument: "ship", botId: bot.id)
        #expect(store.goalControlReply(botId: bot.id, text: "pause")?.contains("paused") == true)
        #expect(store.bots.first { $0.id == bot.id }?.goalState?.status == .paused)
        #expect(store.goalControlReply(botId: bot.id, text: "status")?.contains("paused") == true)
        #expect(store.goalControlReply(botId: bot.id, text: "resume") == nil)
        #expect(store.bots.first { $0.id == bot.id }?.goalState?.status == .active)
        #expect(store.goalControlReply(botId: bot.id, text: "something else") == nil)
    }
}
