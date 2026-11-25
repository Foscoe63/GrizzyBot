import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct TicketBoardTests {
    func board() -> TicketBoardStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TicketBoardStore(root: dir)
    }

    @Test func createFindAndNumber() throws {
        let b = board()
        let a = try #require(b.create(title: "Fix login", detail: "d", priority: .high, assignee: nil, by: "owner"))
        let c = try #require(b.create(title: "Docs", detail: "", priority: .low, assignee: "bot1", by: "bot2"))
        #expect(a.number == 1 && c.number == 2)
        #expect(b.find("#2")?.title == "Docs")
        #expect(b.create(title: "  ", detail: "", priority: .normal, assignee: nil, by: "x") == nil)
    }

    @Test func boardOrdersByPriorityAndHidesClosed() throws {
        let b = board()
        let low = try #require(b.create(title: "low", detail: "", priority: .low, assignee: nil, by: "o"))
        _ = b.create(title: "urgent", detail: "", priority: .urgent, assignee: nil, by: "o")
        let done = try #require(b.create(title: "done", detail: "", priority: .normal, assignee: nil, by: "o"))
        b.update(done.id) { $0.status = .done }
        let open = b.board()
        #expect(open.map(\.title) == ["urgent", "low"])
        #expect(b.board(includeClosed: true).count == 3)
        #expect(b.board(assignee: "nobody").isEmpty)
        _ = low
    }

    @Test func commentsAndStatusParsing() throws {
        let b = board()
        let t = try #require(b.create(title: "T", detail: "", priority: .normal, assignee: nil, by: "o"))
        #expect(b.comment(t.id, author: "bot", text: "on it")?.comments.count == 1)
        #expect(b.comment(t.id, author: "bot", text: "  ") == nil)
        #expect(TicketStatus.parse("In review") == .inReview)
        #expect(TicketStatus.parse("won't do") == .wontDo)
        #expect(TicketStatus.parse("nonsense") == nil)
    }

    @MainActor @Test func toolsAreOffered() {
        let tools = AgentToolCatalog.chatTools(enabledIds: [])
        let names = Set(tools.map { $0.function.name })
        for id in TicketBoardStore.toolIds { #expect(names.contains(id)) }
        #expect(!names.contains("update_bot"))
        let managers = Set(AgentToolCatalog.chatTools(enabledIds: ["spawn_bot"]).map { $0.function.name })
        #expect(managers.contains("update_bot") && managers.contains("get_bot_instructions"))
    }
}

@Suite @MainActor struct TicketScreenStoreTests {
    @Test func ownerActionsRefreshAndPersist() throws {
        let store = AppStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)"), delayScale: 0)
        let before = store.ticketRevision
        #expect(store.createTicket(title: "Ship it", detail: "", priority: .high, assigneeId: nil))
        let t = try #require(store.tickets(includeClosed: true).first)
        store.setTicketStatus(t.id, .inReview)
        store.commentOnTicket(t.id, text: "looks good")
        #expect(store.tickets(includeClosed: false).first?.status == .inReview)
        #expect(store.tickets(includeClosed: true).first?.comments.first?.author == "owner")
        #expect(store.ticketRevision > before)
        store.deleteTicket(t.id)
        #expect(store.tickets(includeClosed: true).isEmpty)
    }
}
