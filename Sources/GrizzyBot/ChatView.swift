import GrizzyBotCore
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var hoverComputer = false
    @State private var showTaskPicker = false
    @State private var newTaskTitle = ""
    @State private var confirmClearChat = false
    @State private var confirmDeleteChat = false
    @State private var snapshotName = ""
    @State private var sessionNotice: String?

    private var bot: Bot? { store.activeBot }
    private var group: GroupRoom? {
        guard let id = store.activeGroupId else { return nil }
        return store.groups.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let group {
                groupMessages(group)
                groupInputBar(group)
            } else if bot == nil {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Text("Create a bot to start chatting.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
            } else {
                messages
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.activeBotId) { _, _ in
            draft = ""
        }
        .onChange(of: store.activeGroupId) { _, _ in
            draft = ""
        }
    }

    private var header: some View {
        HStack {
            if let group {
                HStack(spacing: 10) {
                    Text("◇")
                        .foregroundStyle(Theme.textLetter)
                    Text(group.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                        .lineLimit(1)
                }
            } else if let bot {
                Button {
                    store.openPanel(.settings)
                } label: {
                    HStack(spacing: 10) {
                        BotAvatarView(color: bot.color, size: 26)
                        Text(bot.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        if bot.chiefOfStaff {
                            Text("Chief")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)

                taskPicker(bot)
            }
            Spacer()
            sessionMenu
            if group == nil {
                Button {
                    store.toggleComputerPanel()
                } label: {
                    MonitorIcon()
                        .stroke(Theme.textSub, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 18)
                        .frame(width: 30, height: 34)
                        .background(
                            store.panel == .computer ? Color(hex: "#1B1B1E") : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hoverComputer = $0 }
                .opacity(hoverComputer || store.panel == .computer ? 1 : 0.9)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
        }
    }

    private var sessionMenu: some View {
        Menu {
            Button("Save snapshot") {
                snapshotName = store.activeSessionTitle
                let meta = store.saveWorkspaceSnapshot(name: snapshotName)
                sessionNotice = meta.map { "Saved “\($0.name)”" } ?? "Could not save"
            }
            Button("Export chat…") {
                guard let data = store.exportActiveChatJSON() else { return }
                SessionFilePanel.save(data: data, filename: store.chatExportFilename(json: true), utType: .json)
            }
            Button("Export transcript…") {
                SessionFilePanel.saveText(store.exportActiveChatMarkdown(), filename: store.chatExportFilename(json: false))
            }
            Button("Import chat…") {
                guard let data = SessionFilePanel.openJSON() else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let export = try? decoder.decode(ChatSessionExport.self, from: data) {
                    store.importChat(export)
                    sessionNotice = "Imported \(export.messages.count) messages"
                } else {
                    sessionNotice = "Not a chat export"
                }
            }
            Divider()
            Button("Clear chat…", role: .destructive) {
                confirmClearChat = true
            }
            .disabled(store.activeSessionMessageCount == 0)
            Button("Delete chat…", role: .destructive) {
                confirmDeleteChat = true
            }
            .disabled(store.activeSessionKey == nil)
        } label: {
            Text("Session")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.bgCard)
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .disabled(store.activeSessionKey == nil)
        .alert("Clear this chat?", isPresented: $confirmClearChat) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                store.clearActiveChat()
                sessionNotice = "Chat cleared"
            }
        } message: {
            Text("Removes messages from “\(store.activeSessionTitle)”. The bot stays. You can restore from a snapshot if you saved one.")
        }
        .alert("Delete this chat?", isPresented: $confirmDeleteChat) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteActiveChat()
                sessionNotice = "Chat deleted"
            }
        } message: {
            Text("Stops any run and wipes this thread. Task chats are removed from the list.")
        }
        .alert("Session", isPresented: Binding(
            get: { sessionNotice != nil },
            set: { if !$0 { sessionNotice = nil } }
        )) {
            Button("OK", role: .cancel) { sessionNotice = nil }
        } message: {
            Text(sessionNotice ?? "")
        }
    }

    private func taskPicker(_ bot: Bot) -> some View {
        Menu {
            Button("Main thread") {
                store.selectTask(botId: bot.id, taskId: nil)
            }
            ForEach(bot.tasks) { task in
                Button(task.title) {
                    store.selectTask(botId: bot.id, taskId: task.id)
                }
            }
            Divider()
            Button("New task…") {
                newTaskTitle = ""
                showTaskPicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(bot.activeTaskId.flatMap { id in bot.tasks.first(where: { $0.id == id })?.title } ?? "Main")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.bgCard)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .popover(isPresented: $showTaskPicker) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New task")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                TextField("Title", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.bgSearch)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button("Create") {
                    let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = store.createTask(botId: bot.id, title: title.isEmpty ? "New task" : title)
                    showTaskPicker = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textCream)
            }
            .padding(14)
            .frame(width: 240)
            .background(Theme.bgUserMenu)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if let bot {
                        ForEach(store.messages(for: bot.id)) { message in
                            MessageView(message: message, botId: bot.id)
                                .id(message.id)
                        }
                        if store.isRunActive(botId: bot.id) {
                            Text("working…")
                                .font(.system(size: 14.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 13)
                                .background(Theme.bgBubble)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .grizzyPulse()
                                .id("working-pulse")
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .grizzyScroll()
            .onChange(of: bot.map { store.messages(for: $0.id).count } ?? 0) { _, _ in
                if let last = bot.flatMap({ store.messages(for: $0.id).last }) {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupMessages(_ group: GroupRoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if !group.bulletin.isEmpty {
                        Text(group.bulletin)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    ForEach(store.threads[group.id]?.messages ?? []) { message in
                        MessageView(message: message, botId: group.memberIds.first ?? group.id)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .grizzyScroll()
            .onChange(of: store.threads[group.id]?.messages.count ?? 0) { _, _ in
                if let last = store.threads[group.id]?.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 14) {
            Text("+")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textLetter)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle().stroke(Theme.borderInputsDark, lineWidth: 1)
                }

            TextField(
                bot.map { "Message \($0.name)" } ?? "Message",
                text: $draft
            )
            .font(.system(size: 15.5))
            .foregroundStyle(Theme.textInput)
            .textFieldStyle(.plain)
            .onSubmit { send() }

            Button {
                if let bot, store.isRunActive(botId: bot.id) {
                    store.stopRun(botId: bot.id)
                } else {
                    send()
                }
            } label: {
                Text(bot.map { store.isRunActive(botId: $0.id) } == true ? "■" : "↑")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textCream)
                    .frame(width: 36, height: 36)
                    .background(Theme.bgCream)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(Theme.bgInputBar)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Theme.borderSearch, lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func groupInputBar(_ group: GroupRoom) -> some View {
        HStack(spacing: 14) {
            TextField("Message \(group.name)", text: $draft)
                .font(.system(size: 15.5))
                .foregroundStyle(Theme.textInput)
                .textFieldStyle(.plain)
                .onSubmit { sendGroup(group) }

            Button {
                sendGroup(group)
            } label: {
                Text("↑")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textCream)
                    .frame(width: 36, height: 36)
                    .background(Theme.bgCream)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .background(Theme.bgInputBar)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Theme.borderSearch, lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func send() {
        guard let bot else { return }
        let text = draft
        draft = ""
        store.send(botId: bot.id, text: text)
    }

    private func sendGroup(_ group: GroupRoom) {
        let text = draft
        draft = ""
        store.sendGroupMessage(groupId: group.id, text: text)
    }
}

private struct MonitorIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 2 * sx, y: rect.minY + 4 * sy, width: 20 * sx, height: 13 * sy),
            cornerSize: CGSize(width: 2 * sx, height: 2 * sy)
        )
        path.move(to: p(9, 17))
        path.addLine(to: p(9, 20))
        path.addLine(to: p(15, 20))
        path.addLine(to: p(15, 17))
        path.move(to: p(7, 20))
        path.addLine(to: p(17, 20))
        return path
    }
}
