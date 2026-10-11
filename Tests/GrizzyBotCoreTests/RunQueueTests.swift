import Foundation
import GrizzyBotCore
import Testing

@Suite("Run queue")
struct RunQueuePlannerTests {
    @Test("steer note numbers several messages and names the intent")
    func steerNote() {
        let one = QueuePlanner.steerNote(["actually use Python"])
        #expect(one.contains("actually use Python"))
        #expect(one.contains("while you were working"))
        let many = QueuePlanner.steerNote(["a", " ", "b"])
        #expect(many.contains("1. a"))
        #expect(many.contains("2. b"))
        #expect(QueuePlanner.steerNote(["", "  "]).isEmpty)
    }

    @Test("collect merges, followup keeps apart")
    func turns() {
        let held = [
            QueuedSend(messageId: "1", text: "one"),
            QueuedSend(messageId: "2", text: "two"),
        ]
        #expect(QueuePlanner.turns(for: held, mode: .collect).count == 1)
        #expect(QueuePlanner.turns(for: held, mode: .steer).count == 1)
        #expect(QueuePlanner.turns(for: held, mode: .followup).count == 2)
        #expect(QueuePlanner.turns(for: [], mode: .followup).isEmpty)
        #expect(QueuePlanner.merge(["one", "two"]) == "one\n\ntwo")
        #expect(QueuePlanner.merge(["solo"]) == "solo")
    }

    @Test("inbox drains once")
    func inbox() {
        let inbox = RunInbox()
        #expect(inbox.isEmpty)
        inbox.push(QueuedSend(messageId: "1", text: "a"))
        inbox.push(QueuedSend(messageId: "2", text: "b"))
        #expect(inbox.drain().map(\.text) == ["a", "b"])
        #expect(inbox.drain().isEmpty)
    }

    @Test("queue mode survives a config round trip and defaults to steer")
    func configRoundTrip() throws {
        var config = AppConfig()
        #expect(config.queueMode == .steer)
        config.queueMode = .followup
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data).queueMode == .followup)
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(legacy.queueMode == .steer)
    }
}

@Suite("Agent loop steering")
struct AgentLoopSteerTests {
    private let endpoint = ModelEndpoint(
        provider: "openrouter",
        model: "test",
        baseURL: "https://example.com/v1",
        apiKey: "k"
    )

    @Test("a message that arrives while the model is answering gets its own step")
    func steerBeforeFinishing() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(text: "first answer"),
            ChatCompletionResponse(text: "revised answer"),
        ])
        let pending = SteerBox(["use Python instead"])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "Scout",
                prompt: "write it",
                tools: [],
                steer: { pending.take() }
            ),
            execute: { _, _ in AgentToolCallResult(output: "") }
        )
        #expect(result.text == "revised answer")
        #expect(client.requests.count == 2)
        let secondRequest = client.requests[1].messages.compactMap(\.content).joined(separator: "\n")
        #expect(secondRequest.contains("use Python instead"))
    }

    @Test("with nothing waiting the loop ends as before")
    func noSteer() async throws {
        let client = QueueChatClient([ChatCompletionResponse(text: "only answer")])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(
                endpoint: endpoint,
                botName: "Scout",
                prompt: "hi",
                tools: [],
                steer: { [] }
            ),
            execute: { _, _ in AgentToolCallResult(output: "") }
        )
        #expect(result.text == "only answer")
        #expect(client.requests.count == 1)
    }
}

private final class SteerBox: @unchecked Sendable {
    private var items: [String]
    private let lock = NSLock()
    init(_ items: [String]) { self.items = items }
    func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}

/// Parks the first model call until the test lets it go, so "the bot is still working"
/// is something the test controls rather than a race.
private final class HoldingChatClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var open = false
    private var prompts: [String] = []

    func release() {
        lock.lock()
        open = true
        lock.unlock()
    }

    var seenPrompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }

    private func record(_ prompt: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        prompts.append(prompt)
        return calls == 1
    }

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let first = record(request.messages.last(where: { $0.role == "user" })?.content ?? "")
        if first {
            while !isOpen {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return ChatCompletionResponse(text: first ? "first reply" : "second reply")
    }
}

@Suite("Run queue in the store")
@MainActor
struct RunQueueStoreTests {
    private func tempStore(mode: QueueMode) -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        store.appConfig.queueMode = mode
        return store
    }

    private func wait(_ store: AppStore, botId: String, until done: () -> Bool) async {
        for _ in 0..<400 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("collect holds a mid-run message and answers it after the run, once")
    func collectHoldsThenAnswers() async {
        let store = tempStore(mode: .collect)
        #expect(store.signUp(name: "A", email: "queue-collect@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Ada", title: "")
        let client = HoldingChatClient()
        store.chatCompleter = client

        store.send(botId: bot.id, text: "first")
        await wait(store, botId: bot.id) { client.seenPrompts.count == 1 }
        store.send(botId: bot.id, text: "second")
        store.send(botId: bot.id, text: "third")

        // Still on the first run: nothing new has been asked of the model.
        #expect(client.seenPrompts.count == 1)
        #expect(store.threads[bot.id]?.messages.filter { $0.role == .user }.count == 3)

        client.release()
        await wait(store, botId: bot.id) {
            client.seenPrompts.count == 2 && store.threads[bot.id]?.run?.status == .completed
        }
        #expect(client.seenPrompts.count == 2)
        #expect(client.seenPrompts[1].contains("second"))
        #expect(client.seenPrompts[1].contains("third"))
        let users = (store.threads[bot.id]?.messages ?? []).filter { $0.role == .user }.map(\.firstText)
        // Filed again after the reply as one merged message, not left as two loose ones.
        #expect(users == ["first", "second\n\nthird"])
    }

    @Test("stop discards what was waiting")
    func stopDropsQueue() async {
        let store = tempStore(mode: .collect)
        #expect(store.signUp(name: "A", email: "queue-stop@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Ada", title: "")
        let client = HoldingChatClient()
        store.chatCompleter = client

        store.send(botId: bot.id, text: "first")
        await wait(store, botId: bot.id) { client.seenPrompts.count == 1 }
        store.send(botId: bot.id, text: "second")
        store.stopRun(botId: bot.id)
        client.release()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(client.seenPrompts.count == 1)
        #expect(store.threads[bot.id]?.run?.status == .cancelled)
    }
}
