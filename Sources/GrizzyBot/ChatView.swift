import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var hoverComputer = false
    @State private var hoverCanvas = false
    @State private var showTaskPicker = false
    @State private var newTaskTitle = ""
    @State private var confirmClearChat = false
    @State private var confirmDeleteChat = false
    @State private var snapshotName = ""
    @State private var sessionNotice: String?
    @State private var pendingFiles: [URL] = []
    @State private var dictation = DictationSession()
    @State private var searchQuery = ""
    @State private var searchThisThread = false
    @State private var pasteOverride = false

    private var bot: Bot? { store.activeBot }
    private var group: GroupRoom? {
        guard let id = store.activeGroupId else { return nil }
        return store.groups.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.chatSearchOpen {
                chatSearchBar
            }
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
                if let banner = bot.flatMap({ BotCapabilitySummary.of($0).banner }) {
                    capabilityBanner(banner)
                }
                messages
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.activeBotId) { _, _ in
            draft = ""
            pendingFiles = []
        }
        .onChange(of: store.activeGroupId) { _, _ in
            draft = ""
            pendingFiles = []
        }
        .onChange(of: store.pendingComposerText) { _, text in
            if let text {
                draft = text
                store.pendingComposerText = nil
            }
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
            if group == nil, let bot, store.canUndoSend(botId: bot.id) {
                Button("Undo send") {
                    if let text = store.undoSend(botId: bot.id) {
                        draft = text
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            }
            Button {
                store.chatSearchOpen.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(store.chatSearchOpen ? Theme.orange : Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Search chats")
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
                Button {
                    store.toggleCanvasPanel()
                } label: {
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSub)
                        .frame(width: 30, height: 34)
                        .background(
                            store.panel == .canvas || store.canvasOpen ? Color(hex: "#1B1B1E") : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Canvas")
                .onHover { hoverCanvas = $0 }
                .opacity(hoverCanvas || store.panel == .canvas || store.canvasOpen ? 1 : 0.9)
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
            Button("Undo send") {
                if let bot, let text = store.undoSend(botId: bot.id) {
                    draft = text
                    sessionNotice = "Send undone"
                }
            }
            .disabled(bot.map { !store.canUndoSend(botId: $0.id) } ?? true)
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

    private func capabilityBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.orange)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Tools") {
                store.openPanel(.settings)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSidebarIcon)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.orange.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
        }
    }

    private var chatSearchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search chats", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textBright)
                Toggle("This thread", isOn: $searchThisThread)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Button("Done") {
                    store.closeChatSearch()
                    searchQuery = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            }
            let hits = store.searchChats(query: searchQuery, currentThreadOnly: searchThisThread)
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                if hits.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(hits.prefix(12)) { hit in
                        Button {
                            store.jumpToSearchHit(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.botName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textLetter)
                                Text(hit.snippet)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textBright)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.bgCard)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
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
                                .overlay {
                                    if store.highlightMessageId == message.id {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Theme.orange, lineWidth: 1)
                                    }
                                }
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
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: store.highlightMessageId) { _, id in
                if let id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        if let last = bot.flatMap({ store.messages(for: $0.id).last }) {
            withAnimation {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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

    private var pasteWarning: String? {
        let local = LocalProviders.isLocal(bot?.modelProvider ?? store.modelProvider ?? "")
        if pasteOverride { return nil }
        return PasteGuard.warning(for: draft, localModel: local)
    }

    private var slashSuggestions: [AgentSkill] {
        guard let bot else { return [] }
        return SlashCommand.suggestions(draft: draft, skills: store.enabledSkills(for: bot.id))
    }

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Skills")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(slashSuggestions) { skill in
                Button {
                    draft = "/\(skill.id) "
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(skill.id)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                        Text(skill.description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Tab or click to insert · /help lists all")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.borderSearch, lineWidth: 1)
        }
        .padding(.horizontal, 28)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pasteWarning {
                HStack(alignment: .top, spacing: 8) {
                    Text(pasteWarning)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Send anyway") {
                        pasteOverride = true
                        send()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                }
                .padding(.horizontal, 28)
            }
            if let bot {
                composerModelPicker(bot)
                    .padding(.horizontal, 28)
                    .padding(.top, pasteWarning == nil && pendingFiles.isEmpty ? 8 : 0)
            }
            if !pendingFiles.isEmpty {
                HStack(spacing: 8) {
                    ForEach(pendingFiles, id: \.path) { url in
                        HStack(spacing: 6) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textGhost)
                                .lineLimit(1)
                            Button {
                                pendingFiles.removeAll { $0 == url }
                            } label: {
                                Text("✕")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.bgCard)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 28)
            }
            if dictation.isListening, !dictation.transcript.isEmpty {
                Text(dictation.transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 28)
            }
            if let error = dictation.error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.redError)
                    .padding(.horizontal, 28)
            }
            if !slashSuggestions.isEmpty {
                slashMenu
            }
            HStack(spacing: 14) {
                Button {
                    if let urls = SessionFilePanel.openFiles() {
                        pendingFiles.append(contentsOf: urls)
                    }
                } label: {
                    Text("+")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textLetter)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Circle().stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Attach files")

                PromptComposer(
                    text: $draft,
                    placeholder: bot.map { "Message \($0.name) · / for skills" } ?? "Message",
                    onSend: send,
                    onTabComplete: completeSlashSuggestion
                )
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 110, alignment: .leading)

                Button {
                    if dictation.isListening {
                        let spoken = dictation.stop()
                        if !spoken.isEmpty {
                            draft = draft.isEmpty ? spoken : draft + " " + spoken
                        }
                    } else {
                        dictation.start()
                    }
                } label: {
                    Text(dictation.isListening ? "●" : "🎤")
                        .font(.system(size: 13))
                        .foregroundStyle(dictation.isListening ? Theme.orange : Theme.textLetter)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(dictation.isListening ? "Stop dictation" : "Dictate")

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
            .padding(.top, pendingFiles.isEmpty ? 4 : 0)
            .padding(.bottom, 24)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? URL {
                        urls.append(url)
                    } else if let data = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                await MainActor.run {
                    pendingFiles.append(contentsOf: urls)
                }
            }
            return true
        }
    }

    private func composerModelChoices(for bot: Bot) -> [BotModelChoice] {
        let workspaceProvider = store.modelProvider ?? ModelCatalog.defaultProvider
        var options = BotModelChoice.choices(
            workspaceProvider: workspaceProvider,
            workspaceModel: store.modelId,
            fetched: store.fetchedModels(for: workspaceProvider),
            enabledProviders: store.enabledModelSources()
        )
        let current = BotModelChoice.current(bot: bot)
        if !options.contains(where: { $0.id == current.id }) {
            options.insert(current, at: 1)
        }
        return options
    }

    private func composerModelPicker(_ bot: Bot) -> some View {
        let current = BotModelChoice.current(bot: bot)
        let workspaceModel = store.modelId
        return Menu {
            ForEach(composerModelChoices(for: bot)) { choice in
                Button {
                    store.setBotModel(bot.id, choice: choice)
                } label: {
                    if choice.id == current.id {
                        Label(choice.menuLabel(workspaceModel: workspaceModel), systemImage: "checkmark")
                    } else {
                        Text(choice.menuLabel(workspaceModel: workspaceModel))
                    }
                }
            }
            Divider()
            Button("Connect models…") {
                store.openModelSettings()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Text(BotModelChoice.activeLabel(bot: bot, workspaceModel: workspaceModel))
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
        .help("Model for this bot")
    }

    private func groupInputBar(_ group: GroupRoom) -> some View {
        HStack(spacing: 14) {
            PromptComposer(
                text: $draft,
                placeholder: "Message \(group.name)",
                onSend: { sendGroup(group) }
            )
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 110, alignment: .leading)

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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingFiles
        if text.isEmpty && files.isEmpty && !dictation.isListening { return }
        let local = LocalProviders.isLocal(bot.modelProvider ?? store.modelProvider ?? "")
        if !pasteOverride, PasteGuard.warning(for: text, localModel: local) != nil {
            return
        }
        draft = ""
        pendingFiles = []
        pasteOverride = false
        if dictation.isListening {
            let spoken = dictation.stop()
            store.send(
                botId: bot.id,
                text: spoken.isEmpty ? text : (text.isEmpty ? spoken : text + " " + spoken),
                attaching: files
            )
            return
        }
        store.send(botId: bot.id, text: text, attaching: files)
    }

    @discardableResult
    private func completeSlashSuggestion() -> Bool {
        guard let first = slashSuggestions.first else { return false }
        draft = "/\(first.id) "
        return true
    }

    private func sendGroup(_ group: GroupRoom) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
