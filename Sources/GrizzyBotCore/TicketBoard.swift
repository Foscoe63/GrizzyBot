import Foundation

public enum TicketStatus: String, Codable, Sendable, CaseIterable {
    case todo, inProgress = "in_progress", inReview = "in_review", blocked, done, wontDo = "wont_do"

    public var label: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        case .wontDo: return "Won't do"
        }
    }

    public var isOpen: Bool { self != .done && self != .wontDo }

    /// Lenient: "in progress", "In review", "wont do", "won't do".
    public static func parse(_ raw: String) -> TicketStatus? {
        let key = raw.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return TicketStatus(rawValue: key) ?? (key == "wontdo" ? .wontDo : nil)
    }
}

public enum TicketPriority: String, Codable, Sendable, CaseIterable {
    case low, normal, high, urgent
}

public struct TicketComment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// A bot id, or "owner" for the person.
    public var author: String
    public var text: String
    public var at: Date
}

/// One shared piece of work, for people and bots alike.
public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    public var detail: String
    public var status: TicketStatus
    public var priority: TicketPriority
    /// The bot who owns it, if any.
    public var assigneeBotId: String?
    public var createdBy: String
    public var createdAt: Date
    public var updatedAt: Date
    public var comments: [TicketComment]
}

public struct TicketBoardData: Codable, Sendable, Equatable {
    public var nextNumber = 1
    public var tickets: [Ticket] = []
}

/// File-backed board shared by every bot and the person. One JSON file, so a routine that runs with the app closed sees the same board.
public struct TicketBoardStore: Sendable {
    public static let toolIds: [String] = ["ticket_create", "ticket_update", "ticket_comment", "ticket_get", "board_tickets"]
    public static let maxTickets = 500
    public static let maxTextChars = 4_000
    public static let maxComments = 100

    let url: URL

    public init(root: URL) {
        url = root.appendingPathComponent("tickets.json")
    }

    public func load() -> TicketBoardData {
        (try? JSONDecoder().decode(TicketBoardData.self, from: Data(contentsOf: url))) ?? TicketBoardData()
    }

    private func save(_ data: TicketBoardData) {
        if let encoded = try? JSONEncoder().encode(data) { try? encoded.write(to: url, options: .atomic) }
    }

    static func clip(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= maxTextChars ? t : String(t.prefix(maxTextChars)) + "…"
    }

    public func create(title: String, detail: String, priority: TicketPriority, assignee: String?, by author: String, now: Date = .now) -> Ticket? {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !cleanTitle.isEmpty else { return nil }
        var data = load()
        guard data.tickets.count < Self.maxTickets else { return nil }
        let ticket = Ticket(
            id: Ids.new(), number: data.nextNumber, title: cleanTitle, detail: Self.clip(detail), status: .todo, priority: priority,
            assigneeBotId: assignee, createdBy: author, createdAt: now, updatedAt: now, comments: []
        )
        data.nextNumber += 1
        data.tickets.append(ticket)
        save(data)
        return ticket
    }

    /// Finds a ticket by number ("12", "#12") or id.
    public func find(_ ref: String) -> Ticket? {
        let key = ref.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let data = load()
        if let n = Int(key) { return data.tickets.first { $0.number == n } }
        return data.tickets.first { $0.id == key }
    }

    @discardableResult
    public func update(_ id: String, now: Date = .now, _ change: (inout Ticket) -> Void) -> Ticket? {
        var data = load()
        guard let idx = data.tickets.firstIndex(where: { $0.id == id }) else { return nil }
        change(&data.tickets[idx])
        data.tickets[idx].title = String(data.tickets[idx].title.prefix(160))
        data.tickets[idx].detail = Self.clip(data.tickets[idx].detail)
        data.tickets[idx].updatedAt = now
        save(data)
        return data.tickets[idx]
    }

    @discardableResult
    public func comment(_ id: String, author: String, text: String, now: Date = .now) -> Ticket? {
        let clean = Self.clip(text)
        guard !clean.isEmpty else { return nil }
        return update(id, now: now) { t in
            guard t.comments.count < Self.maxComments else { return }
            t.comments.append(TicketComment(id: Ids.new(), author: author, text: clean, at: now))
        }
    }

    /// Open tickets first (urgent first, then oldest), optionally for one owner or one status.
    public func board(assignee: String? = nil, status: TicketStatus? = nil, includeClosed: Bool = false) -> [Ticket] {
        load().tickets
            .filter { assignee == nil || $0.assigneeBotId == assignee }
            .filter { status == nil || $0.status == status }
            .filter { includeClosed || status != nil || $0.status.isOpen }
            .sorted { a, b in
                let rank: (TicketPriority) -> Int = { [.urgent: 0, .high: 1, .normal: 2, .low: 3][$0] ?? 2 }
                return (rank(a.priority), a.number) < (rank(b.priority), b.number)
            }
    }

    public static func line(_ t: Ticket, botName: (String) -> String) -> String {
        let owner = t.assigneeBotId.map { " → \(botName($0))" } ?? ""
        return "#\(t.number) [\(t.status.label)] \(t.title) (\(t.priority.rawValue))\(owner)"
    }
}
