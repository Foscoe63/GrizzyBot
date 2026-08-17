import Foundation
import GrizzyBotCore
import Testing

@Suite("AppStore")
@MainActor
struct StoreTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
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
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.computers[bot.id]?.state == .running)
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
        // Wait for scripted agent (~1.6s * 0.01 = ~16ms, give headroom)
        try? await Task.sleep(for: .milliseconds(400))
        let msgs = store.messages(for: bot.id)
        #expect(msgs.contains(where: { $0.role == .user }))
        #expect(msgs.contains(where: { $0.role == .bot && $0.firstText.contains("on it.") }))
        #expect(store.threads[bot.id]?.run?.status == .completed)
        #expect(store.usage.last?.inputTokens == 12)
        #expect(store.usage.last?.outputTokens == 40)
        #expect(!store.sidebarPreview(for: store.bots.first!).isEmpty)
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
        try? await Task.sleep(for: .milliseconds(400))
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
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.computers[bot.id]?.state == .running)
        store.takeControl(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .user)
        store.release(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .bot)
    }

    @Test("plugins connect revoke")
    func plugins() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "plug@b.com", password: "password1") == nil)
        store.connect(slug: "gmail")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == true)
        store.revoke(slug: "gmail")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.connections.first(where: { $0.slug == "gmail" })?.connected == false)
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

    @Test("clear save export restore and wipe session")
    func sessionLifecycle() async {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "sess@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.send(botId: bot.id, text: "hello there")
        try? await Task.sleep(for: .milliseconds(400))
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
}
