import Foundation
import Testing
@testable import GrizzyBotCore

/// Holds the first turn of one bot until released, so that bot is busy for as long as a test needs.
private final class GateClient: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var held = false
    private(set) var prompts: [String: [String]] = [:]
    let holdBot: String
    init(holdBot: String) { self.holdBot = holdBot }

    func release() { lock.withLock { open = true } }

    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let bot = ByBotClient.name(in: request.messages)
        let user = request.messages.last { $0.role == "user" }?.content ?? ""
        let shouldHold: Bool = lock.withLock {
            prompts[bot, default: []].append(user)
            if bot == holdBot, !held { held = true; return true }
            return false
        }
        if shouldHold { while !lock.withLock({ open }) { try await Task.sleep(nanoseconds: 10_000_000) } }
        return ChatCompletionResponse(text: "done by \(bot)")
    }

    func prompts(for bot: String) -> [String] { lock.withLock { prompts[bot] ?? [] } }
}

@Suite("Queued hand-offs to a busy bot")
@MainActor
struct DelegationQueueTests {
    private func setup() -> (AppStore, Bot, Bot, GateClient) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        store.delegateQueuePollInterval = 0.02
        _ = store.signUp(name: "T", email: "q\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let client = GateClient(holdBot: "Peer")
        store.chatCompleter = client
        let boss = store.createBot(name: "Boss", title: "Lead")
        let peer = store.createBot(name: "Peer", title: "Worker")
        return (store, boss, peer, client)
    }

    private func handOver(_ store: AppStore, from boss: Bot, task: String) async -> AgentToolCallResult {
        await store.executeAgentTool(
            name: "message_bot", argumentsJSON: #"{"name":"Peer","task":"\#(task)"}"#, botId: boss.id, depth: 0,
            endpoint: ModelEndpoint(provider: "p", model: "m", baseURL: "https://localhost", apiKey: ""),
            client: store.chatCompleter!, taint: RunTaint()
        )
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test("a busy bot is queued, not refused or interrupted, and the job starts when it is free")
    func queuesThenStarts() async {
        let (store, boss, peer, client) = setup()
        store.send(botId: peer.id, text: "first job")
        #expect(await eventually { store.peerBusyReason(peer) != nil })

        let result = await handOver(store, from: boss, task: "second job")
        #expect(result.output.contains("queued"))
        #expect(!result.output.contains("Don't pile"))
        let entry = store.botChat.last { $0.toBotId == peer.id }
        #expect(entry?.outcome == .queued)
        // Not slipped into the run in flight.
        #expect(!client.prompts(for: "Peer").contains { $0.contains("second job") })

        client.release()
        #expect(await eventually { client.prompts(for: "Peer").contains { $0.contains("second job") } })
        #expect(client.prompts(for: "Peer").first?.contains("first job") == true)
        #expect(client.prompts(for: "Peer").last?.contains("Message from Boss") == true)
        #expect(await eventually { store.botChat.last { $0.toBotId == peer.id }?.outcome != .queued })
        await store.waitForActiveRuns()
    }

    @Test("jobs run in the order they were handed over, and a full line says so")
    func orderAndLimit() async {
        let (store, boss, peer, client) = setup()
        store.send(botId: peer.id, text: "first job")
        #expect(await eventually { store.peerBusyReason(peer) != nil })
        for index in 1...AppStore.maxQueuedPerPeer {
            let r = await handOver(store, from: boss, task: "job \(index)")
            #expect(r.output.contains("queued"), "job \(index)")
        }
        let overflow = await handOver(store, from: boss, task: "one too many")
        #expect(overflow.output.contains("already has"))
        #expect(store.botChat.filter { $0.outcome == .queued }.count == AppStore.maxQueuedPerPeer)

        client.release()
        #expect(await eventually { client.prompts(for: "Peer").count == AppStore.maxQueuedPerPeer + 1 })
        let order = client.prompts(for: "Peer").dropFirst().compactMap { prompt -> Int? in
            (1...AppStore.maxQueuedPerPeer).first { prompt.contains("job \($0)") }
        }
        #expect(order == Array(1...AppStore.maxQueuedPerPeer))
        await store.waitForActiveRuns()
    }

    @Test("a bot that never frees up fails the job and tells the sender")
    func timeout() async {
        let (store, boss, peer, client) = setup()
        store.delegateQueueTimeout = 0.15
        store.send(botId: peer.id, text: "first job")
        #expect(await eventually { store.peerBusyReason(peer) != nil })
        _ = await handOver(store, from: boss, task: "second job")
        #expect(await eventually { store.botChat.last { $0.toBotId == peer.id }?.outcome == .failed })
        #expect(store.threads[store.threadKey(for: boss.id)]?.messages.contains { message in
            message.blocks.contains { if case .text(let t) = $0 { return t.contains("never got to the job") } else { return false } }
        } == true)
        client.release()
        await store.waitForActiveRuns()
        #expect(client.prompts(for: "Peer").count == 1)
    }

    @Test("lending tools to a busy bot is refused with the reason")
    func lendRefused() async {
        let (store, boss, peer, client) = setup()
        store.setBotTool(peer.id, toolId: "shell", enabled: false)
        store.send(botId: peer.id, text: "first job")
        #expect(await eventually { store.peerBusyReason(peer) != nil })
        let result = await store.executeAgentTool(
            name: "message_bot", argumentsJSON: #"{"name":"Peer","task":"x","grant_tools":"shell"}"#, botId: boss.id, depth: 0,
            endpoint: ModelEndpoint(provider: "p", model: "m", baseURL: "https://localhost", apiKey: ""),
            client: client, taint: RunTaint()
        )
        #expect(result.pause == nil)
        #expect(result.output.contains("Lending tools needs it free"), "\(result.output)")
        client.release()
        await store.waitForActiveRuns()
    }

    @Test("jobs left queued when the app closed are failed on the next launch")
    func relaunch() {
        let (store, _, peer, _) = setup()
        store.botChat.append(BotChatEntry(fromBotId: "a", toBotId: peer.id, text: "x", outcome: .queued))
        store.expireQueuedDelegations()
        #expect(store.botChat.last?.outcome == .failed)
    }
}
