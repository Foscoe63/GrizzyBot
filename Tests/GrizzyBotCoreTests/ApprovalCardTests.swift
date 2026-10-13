import Foundation
import GrizzyBotCore
import Testing

@Suite("Orphaned approval cards")
@MainActor
struct ApprovalCardTests {
    private func card(_ status: ApprovalStatus, _ n: Int) -> ThreadMessage {
        ThreadMessage(id: "m\(n)", threadId: "t", seq: n, role: .bot, blocks: [.approval(tool: "shell.exec", detail: "echo \(n)", status: status)])
    }

    private func statuses(_ thread: ThreadData?) -> [ApprovalStatus] {
        (thread?.messages ?? []).flatMap(\.blocks).compactMap {
            if case .approval(_, _, let status) = $0 { return status }
            return nil
        }
    }

    private func run(_ status: RunStatus) -> Run {
        Run(id: "r", botId: "b", threadId: "t", status: status, trigger: "user")
    }

    @Test("a pending card with nothing waiting behind it is cancelled; answered cards are left alone")
    func orphanCancelled() {
        var thread = ThreadData(threadId: "t", messages: [card(.pending, 0), card(.allowed, 1), card(.denied, 2)], run: run(.cancelled))
        let first = thread.cancelOrphanedApprovals()
        #expect(first)
        #expect(statuses(thread) == [.cancelled, .allowed, .denied])
        let second = thread.cancelOrphanedApprovals()
        #expect(!second)
    }

    @Test("a card with a live request, or a run still waiting, is left pending")
    func liveCardsKept() {
        let pending = PendingAgentTool(name: "shell", arguments: "{}", tool: "shell.exec", detail: "echo 0")
        var live = ThreadData(threadId: "t", messages: [card(.pending, 0)], run: run(.waitingInput), pendingTool: pending)
        let liveChanged = live.cancelOrphanedApprovals()
        #expect(!liveChanged)
        #expect(statuses(live) == [.pending])

        var waiting = ThreadData(threadId: "t", messages: [card(.pending, 0)], run: run(.waitingInput))
        let waitingChanged = waiting.cancelOrphanedApprovals()
        #expect(!waitingChanged)
        #expect(statuses(waiting) == [.pending])
    }

    @Test("saved chats come back with their orphaned cards cancelled")
    func cleanedOnLoad() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "o\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let stale = store.createBot(name: "Stale", title: "Coder")
        let live = store.createBot(name: "Live", title: "Coder")
        let keyStale = stale.id
        let keyLive = live.id
        store.threads[keyStale] = ThreadData(threadId: "t1", messages: [card(.pending, 0)], run: run(.cancelled))
        store.threads[keyLive] = ThreadData(
            threadId: "t2", messages: [card(.pending, 0)], run: run(.waitingInput),
            pendingTool: PendingAgentTool(name: "shell", arguments: "{}", tool: "shell.exec", detail: "echo 0")
        )
        _ = store.createBot(name: "Saver", title: "Saves the workspace")

        let reloaded = AppStore(dataDirectory: dir, delayScale: 0.01)
        #expect(statuses(reloaded.threads[keyStale]) == [.cancelled])
        #expect(statuses(reloaded.threads[keyLive]) == [.pending])
    }
}
