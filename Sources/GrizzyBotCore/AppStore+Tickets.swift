import Foundation

extension AppStore {
    private func botName(_ id: String) -> String { bots.first { $0.id == id }?.name ?? "someone" }

    /// The bot a name or id points at, exactly. Nil when it names nobody or more than one bot.
    private func ticketAssignee(_ raw: String) -> (bot: Bot?, error: String?) {
        switch BotLookup.resolve([raw], in: bots) {
        case .found(let bot): return (bot, nil)
        case .ambiguous(let matches): return (nil, "“\(raw)” matches more than one bot: \(matches.map(\.name).joined(separator: ", ")).")
        case .none: return (nil, "No bot is named “\(raw)”.")
        }
    }

    /// Hands a ticket to the bot it was assigned to. The bot reads the board itself; nothing here lends it any permission.
    private func wakeAssignee(_ ticket: Ticket, by botId: String) {
        guard let assignee = ticket.assigneeBotId, assignee != botId, bots.contains(where: { $0.id == assignee }) else { return }
        send(botId: assignee, text: "Ticket #\(ticket.number) was assigned to you by \(botName(botId)): \(ticket.title)\n\(ticket.detail)\n\nRead it with ticket_get, do the work, comment your progress and set the status when you finish.")
    }

    func handleTicketTool(name: String, args: [String: JSONValue], botId: String) -> AgentToolCallResult {
        let object = JSONValue.object(args)
        func s(_ key: String) -> String { object.stringValue(key) ?? "" }
        func line(_ t: Ticket) -> String { TicketBoardStore.line(t) { self.botName($0) } }

        switch name {
        case "board_tickets":
            let mine: Bool = { if case .bool(let b)? = args["mine"] { return b }; return ["true", "yes", "1"].contains(s("mine").lowercased()) }()
            let status = TicketStatus.parse(s("status"))
            let tickets = ticketBoard.board(assignee: mine ? botId : nil, status: s("status").isEmpty ? nil : status)
            if tickets.isEmpty { return AgentToolCallResult(output: "No tickets match.") }
            return AgentToolCallResult(output: tickets.prefix(40).map(line).joined(separator: "\n"))

        case "ticket_get":
            guard let t = ticketBoard.find(s("ref")) else { return AgentToolCallResult(output: "No ticket \(s("ref")).") }
            var lines = [line(t), "Created by \(t.createdBy == "owner" ? "the owner" : botName(t.createdBy))", "", t.detail.isEmpty ? "(no description)" : t.detail]
            for c in t.comments.suffix(20) {
                lines.append("— \(c.author == "owner" ? "owner" : botName(c.author)): \(c.text)")
            }
            return AgentToolCallResult(output: lines.joined(separator: "\n"))

        case "ticket_create":
            let priority = TicketPriority(rawValue: s("priority").lowercased()) ?? .normal
            var assignee: Bot?
            if !s("assignee").isEmpty {
                let found = ticketAssignee(s("assignee"))
                if let error = found.error { return AgentToolCallResult(output: error) }
                assignee = found.bot
            }
            guard let ticket = ticketBoard.create(title: s("title"), detail: s("detail"), priority: priority, assignee: assignee?.id, by: botId) else {
                return AgentToolCallResult(output: "A ticket needs a title, and the board holds at most \(TicketBoardStore.maxTickets).")
            }
            wakeAssignee(ticket, by: botId)
            return AgentToolCallResult(output: "Created " + line(ticket))

        case "ticket_update":
            guard let t = ticketBoard.find(s("ref")) else { return AgentToolCallResult(output: "No ticket \(s("ref")).") }
            var newAssignee: String?? = nil
            if !s("assignee").isEmpty {
                if ["none", "nobody", "unassign"].contains(s("assignee").lowercased()) {
                    newAssignee = .some(nil)
                } else {
                    let found = ticketAssignee(s("assignee"))
                    if let error = found.error { return AgentToolCallResult(output: error) }
                    newAssignee = .some(found.bot?.id)
                }
            }
            if !s("status").isEmpty, TicketStatus.parse(s("status")) == nil {
                return AgentToolCallResult(output: "Status must be one of: \(TicketStatus.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let status = TicketStatus.parse(s("status"))
            let priority = TicketPriority(rawValue: s("priority").lowercased())
            let updated = ticketBoard.update(t.id) { ticket in
                if let status { ticket.status = status }
                if let priority { ticket.priority = priority }
                if !s("title").isEmpty { ticket.title = s("title") }
                if !s("detail").isEmpty { ticket.detail = s("detail") }
                if let newAssignee { ticket.assigneeBotId = newAssignee }
            }
            guard let updated else { return AgentToolCallResult(output: "No ticket \(s("ref")).") }
            if let newAssignee, newAssignee != t.assigneeBotId { wakeAssignee(updated, by: botId) }
            return AgentToolCallResult(output: "Updated " + line(updated))

        default: // ticket_comment
            guard let t = ticketBoard.find(s("ref")) else { return AgentToolCallResult(output: "No ticket \(s("ref")).") }
            guard ticketBoard.comment(t.id, author: botId, text: s("text")) != nil else { return AgentToolCallResult(output: "The comment is empty.") }
            return AgentToolCallResult(output: "Commented on #\(t.number).")
        }
    }
}
