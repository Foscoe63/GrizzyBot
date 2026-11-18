import Foundation
import GrizzyBotCore
import Testing

@Suite("Routing memory")
struct RoutingMemoryTests {
    private func decision(_ id: String) -> RouteDecision {
        RouteDecision(botId: id, botName: id, confidence: 0.8, reason: "fits", source: .model)
    }

    @Test("the same message to the same bots has the same key, whatever the case or spacing")
    func keys() {
        let a = RoutingMemory.key(message: "Draft  the Launch post", candidateIds: ["b", "a"])
        let b = RoutingMemory.key(message: "draft the launch post", candidateIds: ["a", "b"])
        #expect(a == b)
        #expect(a != RoutingMemory.key(message: "draft the launch post", candidateIds: ["a", "c"]))
    }

    @Test("a decision is remembered, then expires")
    func remembersThenExpires() {
        var memory = RoutingMemory()
        let now = Date()
        memory.record(key: "k", decision: decision("a"), failed: false, milliseconds: 300, now: now)
        #expect(memory.lookup("k", now: now.addingTimeInterval(60))?.botId == "a")
        #expect(memory.lookup("k", now: now.addingTimeInterval(RoutingMemory.ttl + 1)) == nil)
    }

    @Test("failures and 'nobody in particular' are not remembered, and timings only count answers")
    func notRemembered() {
        var memory = RoutingMemory()
        memory.record(key: "slow", decision: nil, failed: true, milliseconds: 6_000)
        memory.record(key: "none", decision: nil, failed: false, milliseconds: 200)
        #expect(memory.lookup("slow") == nil && memory.lookup("none") == nil)
        #expect(memory.stats.asked == 2 && memory.stats.failed == 1)
        #expect(memory.stats.averageMs == 200)
        #expect(memory.summary.contains("1 timed out"))
    }

    @Test("the memory stays bounded")
    func bounded() {
        var memory = RoutingMemory()
        let start = Date()
        for i in 0..<(RoutingMemory.capacity + 25) {
            memory.record(key: "k\(i)", decision: decision("a"), failed: false, milliseconds: 100, now: start.addingTimeInterval(Double(i)))
        }
        #expect(memory.entries.count == RoutingMemory.capacity)
        #expect(memory.lookup("k0", now: start.addingTimeInterval(200)) == nil)
    }

    @Test("the deadline is clamped to a sane range")
    func clamp() {
        #expect(RoutingMemory.clampedTimeout(0) == 1)
        #expect(RoutingMemory.clampedTimeout(500) == 30)
        #expect(RoutingMemory.clampedTimeout(.nan) == RoutingMemory.defaultTimeout)
        #expect(AppConfig().routerTimeoutSeconds == RoutingMemory.defaultTimeout)
    }
}

/// A router that answers slowly, so the deadline is the thing under test.
private final class SlowRouterClient: ChatCompleting, @unchecked Sendable {
    let inner: ByBotClient
    let delay: UInt64
    init(_ inner: ByBotClient, delaySeconds: Double) { self.inner = inner; self.delay = UInt64(delaySeconds * 1_000_000_000) }
    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        if ByBotClient.name(in: request.messages) == "ROUTER" { try? await Task.sleep(nanoseconds: delay) }
        return try await inner.complete(request)
    }
}

@Suite("Router timing")
@MainActor
struct RouterTimingTests {
    private func world() -> (store: AppStore, chief: Bot, rae: Bot) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "m\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        store.appConfig.routerModel = ModelChoice(provider: "openrouter", modelId: "router-x")
        let chief = store.createBot(name: "Chief", title: "Chief of staff", enabledTools: ["message_bot"])
        let rae = store.createBot(name: "Rae", title: "Researcher", description: "Searches the web", enabledTools: ["web_search"])
        _ = store.createBot(name: "Ada", title: "Coder", description: "Writes code", enabledTools: ["shell"])
        store.setChiefOfStaff(chief.id, enabled: true)
        store.bots[store.bots.firstIndex { $0.id == chief.id }!].autoDispatch = true
        return (store, store.bots.first { $0.id == chief.id }!, rae)
    }

    @Test("a repeated message is routed from memory without asking the model again")
    func cached() async {
        let w = world()
        let client = ByBotClient([
            "ROUTER": [.success(ChatCompletionResponse(text: #"{"bot":"\#(w.rae.id)","reason":"needs sources"}"#))],
        ])
        w.store.chatCompleter = client
        w.store.send(botId: w.chief.id, text: "what do you think about otters?")
        await w.store.waitForActiveRuns()
        w.store.send(botId: w.chief.id, text: "What do you think  about otters?")
        await w.store.waitForActiveRuns()
        #expect(client.calls(for: "ROUTER") == 1)
        #expect(client.calls(for: "Rae") == 2)
        #expect(w.store.routingMemory.stats.fromCache == 1)
        #expect(w.store.routingMemory.stats.asked == 1)
        #expect(w.store.routingMemory.stats.lastMs != nil)
    }

    @Test("a router slower than the limit is abandoned and the message stays with the Chief of Staff")
    func timesOut() async {
        let w = world()
        w.store.appConfig.routerTimeoutSeconds = 1
        let client = ByBotClient([
            "ROUTER": [.success(ChatCompletionResponse(text: #"{"bot":"\#(w.rae.id)"}"#))],
        ])
        w.store.chatCompleter = SlowRouterClient(client, delaySeconds: 4)
        w.store.send(botId: w.chief.id, text: "what do you think about otters?")
        await w.store.waitForActiveRuns()
        // Had the router not been abandoned its (late) answer would have sent the message to Rae.
        #expect(client.calls(for: "Rae") == 0)
        #expect(client.calls(for: "Chief") == 1)
        #expect(w.store.routingMemory.stats.failed == 1)
    }
}
