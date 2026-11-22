import GrizzyBotCore
import SwiftUI

/// The shared board: one column per status, for you and the bots alike.
struct TicketBoardView: View {
    @Environment(AppStore.self) private var store
    @State private var showClosed = false
    @State private var selectedId: String?
    @State private var composing = false

    private var tickets: [Ticket] { store.tickets(includeClosed: true) }
    private var columns: [TicketStatus] {
        showClosed ? TicketStatus.allCases : TicketStatus.allCases.filter(\.isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tickets.isEmpty {
                VStack(spacing: 8) {
                    Text("No tickets yet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Text("Add one, or ask a bot to. Assigning a ticket to a bot wakes it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns, id: \.self) { status in
                            column(status)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgMain)
        .sheet(isPresented: $composing) { NewTicketSheet() }
        .sheet(item: Binding(get: { selectedId.map { TicketRef(id: $0) } }, set: { selectedId = $0?.id })) { ref in
            TicketDetailSheet(ticketId: ref.id)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.orange)
                    Text("Tickets").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textBright)
                }
                Text("Shared work for you and your bots.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("Show done", isOn: $showClosed)
                .toggleStyle(.switch)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            Button { composing = true } label: {
                Label("New ticket", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
            }
            .accessibilityIdentifier("tickets.new")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private func column(_ status: TicketStatus) -> some View {
        let items = tickets.filter { $0.status == status }
            .sorted { ($0.priority.rank, $0.number) < ($1.priority.rank, $1.number) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textBright)
                Text("\(items.count)").font(.system(size: 11.5)).foregroundStyle(Theme.textGhost)
            }
            ForEach(items) { ticket in
                card(ticket)
            }
            if items.isEmpty {
                Text("Nothing here").font(.system(size: 11.5)).foregroundStyle(Theme.textGhost).padding(.vertical, 6)
            }
        }
        .frame(width: 240, alignment: .topLeading)
    }

    private func card(_ ticket: Ticket) -> some View {
        Button { selectedId = ticket.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(ticket.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text("#\(ticket.number)").foregroundStyle(Theme.textGhost)
                    if ticket.priority == .high || ticket.priority == .urgent {
                        Text(ticket.priority.rawValue).foregroundStyle(Theme.orange)
                    }
                    if let name = store.ticketAssigneeName(ticket) {
                        Text("→ \(name)").foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if !ticket.comments.isEmpty {
                        Image(systemName: "text.bubble").foregroundStyle(Theme.textGhost)
                    }
                }
                .font(.system(size: 11.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bgCard))
        }
        .buttonStyle(.plain)
    }
}

private struct TicketRef: Identifiable { let id: String }

private extension TicketPriority {
    var rank: Int { switch self { case .urgent: 0; case .high: 1; case .normal: 2; case .low: 3 } }
}

private struct NewTicketSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var priority = TicketPriority.normal
    @State private var assignee = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New ticket").font(.system(size: 16, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $detail)
                .font(.system(size: 13))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textGhost.opacity(0.4)))
            Picker("Priority", selection: $priority) {
                ForEach(TicketPriority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Assign to", selection: $assignee) {
                Text("Nobody").tag("")
                ForEach(store.bots.filter { !$0.hidden }) { Text($0.name).tag($0.id) }
            }
            if !assignee.isEmpty {
                Text("The bot is woken with this ticket as soon as you add it.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if store.createTicket(title: title, detail: detail, priority: priority, assigneeId: assignee.isEmpty ? nil : assignee) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct TicketDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticketId: String
    @State private var comment = ""

    private var ticket: Ticket? { store.tickets(includeClosed: true).first { $0.id == ticketId } }

    var body: some View {
        if let ticket {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("#\(ticket.number) \(ticket.title)").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if !ticket.detail.isEmpty {
                    Text(ticket.detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                HStack {
                    Picker("Status", selection: Binding(get: { ticket.status }, set: { store.setTicketStatus(ticket.id, $0) })) {
                        ForEach(TicketStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Priority", selection: Binding(get: { ticket.priority }, set: { store.setTicketPriority(ticket.id, $0) })) {
                        ForEach(TicketPriority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Picker("Owner", selection: Binding(get: { ticket.assigneeBotId ?? "" }, set: { store.assignTicket(ticket.id, to: $0.isEmpty ? nil : $0) })) {
                    Text("Nobody").tag("")
                    ForEach(store.bots.filter { !$0.hidden }) { Text($0.name).tag($0.id) }
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ticket.comments) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(store.botName(c.author)) · \(c.at.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textGhost)
                                Text(c.text).font(.system(size: 13)).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 220)
                HStack {
                    TextField("Add a comment", text: $comment).textFieldStyle(.roundedBorder)
                    Button("Comment") {
                        store.commentOnTicket(ticket.id, text: comment)
                        comment = ""
                    }
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("Delete ticket", role: .destructive) {
                        store.deleteTicket(ticket.id)
                        dismiss()
                    }
                    Spacer()
                }
            }
            .padding(20)
            .frame(width: 480)
        } else {
            Text("This ticket is gone.").padding(40)
        }
    }
}
