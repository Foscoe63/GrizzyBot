import Foundation
import Observation

/// App routing, mirroring rakazo Shell auth redirects.
public enum Route: Sendable, Equatable {
    case welcome
    case signIn
    case signUp
    case onboarding
    case shell
}

/// Which right-side panel is open in the shell.
public enum Panel: String, Sendable, Equatable {
    case computer
    case create
    case settings
    case routine
}

/// Heart of the app: local store mirroring rakazo Shell.tsx state + API behavior.
@MainActor
@Observable
public final class AppStore {
    public var route: Route = .welcome
    public var session: Session?
    public var bots: [Bot] = []
    public var activeBotId: String?
    public var threads: [String: ThreadData] = [:]
    public var routines: [String: [Routine]] = [:]
    public var computers: [String: ComputerStatus] = [:]
    public var connections: [ConnectionItem] = ConnectionCatalog.defaults
    public var usage: [UsageRecord] = []
    public var memory: [MemoryDocument] = []
    public var files: [[String]] = []
    public var deployment: DeploymentSettings = DeploymentSettings()
    public var modelProvider: String?
    public var modelId: String?
    public var apiKey: String?
    public var modelBaseUrl: String?
    public var fetchedModels: [LocalModelRef] = []
    public var modelSettingsOpen: Bool = false
    public var groups: [GroupRoom] = []
    public var appConfig: AppConfig = AppConfig()
    public var customTools: [CustomAgentTool] = []
    public var mcpServers: [McpServer] = []
    public var appSettingsOpen: Bool = false
    public var appSettingsSection: AppSettingsSection = .general
    public var mainView: ShellMainView = .chat
    public var activeGroupId: String?
    public var composerDrafts: [String: String] = [:]

    public enum AppSettingsSection: String, Sendable, CaseIterable, Identifiable {
        case general, connections, computer, voice, tools
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .general: return "General"
            case .connections: return "Connections"
            case .computer: return "Local VM"
            case .voice: return "Voice"
            case .tools: return "Tools"
            }
        }
    }

    public var panel: Panel? = nil
    public var computerOpen: Bool = false
    public var booting: Bool = false
    public var pluginsOpen: Bool = false
    public var showHostPrompt: Bool = false
    public var editingRoutineId: String? = nil
    public var routineDraft: RoutineDraft = RoutineDraft()

    public var connectionPending: Set<String> = []

    private var users: [UserAccount] = []
    private let persistence: Persistence
    private let botHome: BotHomeStore
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var bootTasks: [String: Task<Void, Never>] = [:]
    private var pluginTasks: [String: Task<Void, Never>] = [:]

    /// Shorter delays in tests so `swift test` stays fast.
    public var delayScale: Double = 1.0

    public struct RoutineDraft: Sendable, Equatable {
        public var name: String = ""
        public var prompt: String = ""
        public var preset: Cron.Preset = Cron.defaultPreset()
        /// Bot that will own / run this routine (OpenMausBot "Who does it?").
        public var botId: String = ""

        public init(
            name: String = "",
            prompt: String = "",
            preset: Cron.Preset = Cron.defaultPreset(),
            botId: String = ""
        ) {
            self.name = name
            self.prompt = prompt
            self.preset = preset
            self.botId = botId
        }
    }

    public init(dataDirectory: URL? = nil, delayScale: Double = 1.0) {
        self.persistence = Persistence(root: dataDirectory)
        self.botHome = BotHomeStore(root: self.persistence.root)
        self.delayScale = delayScale
        bootstrap()
    }

    // MARK: - Bootstrap

    /// Stable local account — no sign-in required at launch.
    private static let localEmail = "local@grizzybot.local"
    private static let localName = "Local User"

    private func bootstrap() {
        users = persistence.loadUsers()
        if let session = persistence.loadSession(),
           users.contains(where: { $0.id == session.userId }) {
            enterSession(session)
        } else {
            ensureLocalSession()
        }
    }

    /// Creates or reuses the on-device user and routes straight into onboarding/shell.
    private func ensureLocalSession() {
        let user: UserAccount
        if let existing = users.first(where: { $0.email == Self.localEmail }) {
            user = existing
        } else {
            user = UserAccount(
                id: Ids.new(),
                email: Self.localEmail,
                name: Self.localName,
                passwordHash: Persistence.hashPassword(Ids.new())
            )
            users.append(user)
            persistence.saveUsers(users)
        }
        enterSession(Session(userId: user.id, name: user.name, email: user.email))
    }

    private func enterSession(_ session: Session) {
        self.session = session
        loadWorkspace(for: session.userId)
        route = bots.isEmpty ? .onboarding : .shell
        showHostPrompt = route == .shell && deployment.computerHost == nil
        persistence.saveSession(session)
    }

    private func loadWorkspace(for userId: String) {
        applyWorkspace(persistence.loadWorkspace(userId: userId))
    }

    private func applyWorkspace(_ ws: UserWorkspace) {
        bots = ws.bots
        threads = ws.threads
        routines = ws.routines
        computers = ws.computers
        connections = ws.connections.isEmpty ? ConnectionCatalog.defaults : ws.connections
        usage = ws.usage
        memory = ws.memory
        files = ws.files
        deployment = ws.deployment
        modelProvider = ws.modelProvider
        modelId = ws.modelId
        apiKey = ws.apiKey
        modelBaseUrl = ws.modelBaseUrl
        fetchedModels = ws.fetchedModels
        groups = ws.groups
        appConfig = ws.appConfig
        customTools = ws.customTools
        mcpServers = ws.mcpServers
        if !appConfig.profileName.isEmpty, let existing = session {
            var updated = existing
            updated.name = appConfig.profileName
            if !appConfig.profileEmail.isEmpty { updated.email = appConfig.profileEmail }
            session = updated
        }
        activeBotId = bots.first(where: { !$0.hidden })?.id ?? bots.first?.id
        activeGroupId = nil
        panel = nil
        computerOpen = false
        booting = false
        pluginsOpen = false
        mainView = .chat
    }

    private func currentWorkspace() -> UserWorkspace {
        UserWorkspace(
            bots: bots,
            threads: threads,
            routines: routines,
            computers: computers,
            connections: connections,
            usage: usage,
            memory: memory,
            files: files,
            deployment: deployment,
            modelProvider: modelProvider,
            modelId: modelId,
            apiKey: apiKey,
            modelBaseUrl: modelBaseUrl,
            fetchedModels: fetchedModels,
            groups: groups,
            appConfig: appConfig,
            customTools: customTools,
            mcpServers: mcpServers
        )
    }

    private func save() {
        guard let userId = session?.userId else { return }
        persistence.saveWorkspace(currentWorkspace(), userId: userId)
        persistence.saveUsers(users)
        persistence.saveSession(session)
    }

    private func sleep(_ seconds: Double) async {
        let scaled = max(0.001, seconds * delayScale)
        try? await Task.sleep(for: .seconds(scaled))
    }

    // MARK: - Auth

    public func goToSignIn() { route = .signIn }
    public func goToSignUp() { route = .signUp }
    public func goToWelcome() { route = .welcome }

    public func signUp(name: String, email: String, password: String) -> String? {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            return "Invalid email address"
        }
        guard password.count >= 8 else {
            return "Password must be at least 8 characters"
        }
        if users.contains(where: { $0.email.lowercased() == trimmedEmail }) {
            return "An account with this email already exists."
        }
        let local = trimmedEmail.split(separator: "@").first.map(String.init) ?? "User"
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = resolvedName.isEmpty ? (local.isEmpty ? "User" : local) : resolvedName
        let user = UserAccount(
            id: Ids.new(),
            email: trimmedEmail,
            name: finalName,
            passwordHash: Persistence.hashPassword(password)
        )
        users.append(user)
        session = Session(userId: user.id, name: user.name, email: user.email)
        bots = []
        threads = [:]
        routines = [:]
        computers = [:]
        connections = ConnectionCatalog.defaults
        usage = []
        memory = []
        files = []
        deployment = DeploymentSettings()
        modelProvider = nil
        modelId = nil
        apiKey = nil
        modelBaseUrl = nil
        fetchedModels = []
        activeBotId = nil
        route = .onboarding
        save()
        return nil
    }

    public func signIn(email: String, password: String) -> String? {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = Persistence.hashPassword(password)
        guard let user = users.first(where: { $0.email.lowercased() == trimmedEmail }),
              user.passwordHash == hash else {
            return "Invalid login credentials"
        }
        session = Session(userId: user.id, name: user.name, email: user.email)
        loadWorkspace(for: user.id)
        route = bots.isEmpty ? .onboarding : .shell
        if route == .shell, deployment.computerHost == nil {
            showHostPrompt = true
        }
        save()
        return nil
    }

    public func signOut() {
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        for (_, task) in bootTasks { task.cancel() }
        bootTasks.removeAll()
        panel = nil
        computerOpen = false
        booting = false
        pluginsOpen = false
        showHostPrompt = false
        // No auth gate — return to the local on-device workspace.
        ensureLocalSession()
    }

    public func saveModelSelection(
        provider: String,
        modelId: String,
        apiKey: String?,
        baseUrl: String? = nil,
        models: [LocalModelRef] = []
    ) {
        self.modelProvider = provider
        self.modelId = modelId
        self.apiKey = apiKey
        if let baseUrl, !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.modelBaseUrl = (try? LocalProviders.normalizeBaseUrl(baseUrl, provider: provider)) ?? baseUrl
        } else if LocalProviders.isLocal(provider) {
            self.modelBaseUrl = LocalProviders.def(for: provider)?.defaultBaseUrl
        } else {
            self.modelBaseUrl = nil
        }
        if !models.isEmpty {
            self.fetchedModels = models
        }
        save()
    }

    public func openModelSettings() {
        modelSettingsOpen = true
    }

    public func closeModelSettings() {
        modelSettingsOpen = false
    }

    public func finishOnboarding(
        name: String,
        title: String,
        description: String,
        answers: [String]
    ) {
        let instructions: String
        if answers.isEmpty {
            instructions = description
        } else {
            instructions = "User setup:\n" + answers.map { "- \($0)" }.joined(separator: "\n")
        }
        let bot = createBot(
            name: name,
            title: title,
            description: description,
            instructions: instructions,
            parentBotId: nil
        )
        if var updated = bots.first(where: { $0.id == bot.id }) {
            updated.notifyOnFinish = true
            if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                bots[idx] = updated
            }
        }
        activeBotId = bot.id
        route = .shell
        if deployment.computerHost == nil {
            showHostPrompt = true
        }
        save()
    }

    // MARK: - Bots

    public var activeBot: Bot? {
        guard let id = activeBotId else { return bots.first(where: { !$0.hidden }) ?? bots.first }
        return bots.first(where: { $0.id == id }) ?? bots.first(where: { !$0.hidden }) ?? bots.first
    }

    @discardableResult
    public func createBot(
        name: String,
        title: String = "",
        description: String = "",
        instructions: String = "",
        parentBotId: String? = nil
    ) -> Bot {
        let color = botColors[bots.count % botColors.count]
        let threadId = Ids.new()
        let bot = Bot(
            id: Ids.new(),
            name: name,
            title: title,
            description: description,
            instructions: instructions.isEmpty ? description : instructions,
            color: color,
            notifyOnFinish: true,
            parentBotId: parentBotId,
            threadId: threadId,
            enabledTools: appConfig.defaultEnabledTools.isEmpty
                ? AgentToolCatalog.allIds
                : appConfig.defaultEnabledTools
        )
        bots.append(bot)
        threads[bot.id] = ThreadData(threadId: threadId)
        computers[bot.id] = ComputerStatus(
            botId: bot.id,
            kind: {
                switch appConfig.defaultComputerMode == .auto
                    ? (deployment.computerHost == "this-mac" ? ComputerMode.thisMac : .cloud)
                    : appConfig.defaultComputerMode {
                case .thisMac: return .desktop
                case .off: return .fake
                default: return deployment.sandboxKind
                }
            }(),
            state: .stopped
        )
        routines[bot.id] = []
        memory.append(
            MemoryDocument(
                id: Ids.new(),
                scope: "bot",
                botId: bot.id,
                path: "MEMORY.md",
                content: "# Memory\n\n"
            )
        )
        activeBotId = bot.id
        save()
        return bot
    }

    public func updateBot(
        botId: String,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        instructions: String? = nil
    ) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let name { bots[idx].name = name }
        if let title { bots[idx].title = title }
        if let description { bots[idx].description = description }
        if let instructions { bots[idx].instructions = instructions }
        bots[idx].updatedAt = .now
        save()
    }

    public func deleteBot(_ botId: String) {
        bots.removeAll { $0.id == botId }
        threads.removeValue(forKey: botId)
        computers.removeValue(forKey: botId)
        routines.removeValue(forKey: botId)
        memory.removeAll { $0.botId == botId }
        if activeBotId == botId {
            activeBotId = bots.first?.id
        }
        if panel == .settings || panel == .computer || panel == .routine {
            panel = nil
        }
        computerOpen = false
        if bots.isEmpty {
            route = .onboarding
            showHostPrompt = false
        }
        save()
    }

    public func sidebarPreview(for bot: Bot) -> String {
        if let thread = threads[bot.id], let last = thread.messages.last {
            let text = last.firstText
            if !text.isEmpty {
                return text.count > 80 ? String(text.prefix(80)) + "…" : text
            }
        }
        return bot.preview.isEmpty ? bot.title : bot.preview
    }

    public func sidebarStatus(for bot: Bot) -> String {
        if let run = threads[bot.id]?.run, run.status.isActive {
            return "working"
        }
        return bot.status == "working" ? "working" : "idle"
    }

    // MARK: - Threads / chat

    public func messages(for botId: String) -> [ThreadMessage] {
        messagesForActiveContext(botId: botId)
    }

    public func isRunActive(botId: String) -> Bool {
        threads[threadKey(for: botId)]?.run?.status.isActive == true
            || threads[threadKey(for: botId)]?.run?.status == .waitingInput
    }

    public func send(botId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let threadKey: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        if threads[threadKey] == nil {
            threads[threadKey] = thread
        }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(trimmed)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq

        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: "user"
        )
        thread.run = run
        threads[threadKey] = thread
        bots[botIdx].status = "working"
        bots[botIdx].preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        bots[botIdx].updatedAt = .now
        save()

        let runId = run.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: trimmed)
        }
        runTasks[runId] = task
    }

    private func runAgent(botId: String, threadKey: String, runId: String, prompt: String) async {
        await sleep(0.9)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }

        let progressMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.progress("working…")],
            runId: runId
        )
        thread.messages.append(progressMsg)
        thread.cursor = progressMsg.seq
        threads[threadKey] = thread

        await sleep(0.7)
        guard !Task.isCancelled else {
            await MainActor.run { self.finishCancelled(botId: botId, threadKey: threadKey, runId: runId) }
            return
        }
        guard var thread2 = threads[threadKey], thread2.run?.id == runId else { return }

        // Remove progress bubble
        thread2.messages.removeAll { $0.id == progressMsg.id }

        let reply = ScriptedRuntime.reply(to: prompt, customTools: customTools, mcpServers: mcpServers)
        var blocks: [MessageBlock] = []
        var actionToRun = reply.action

        if let proposed = actionToRun,
           let bot = bots.first(where: { $0.id == botId }),
           !bot.isToolEnabled(proposed.toolId) {
            let label = AgentToolCatalog.label(for: proposed.toolId, custom: customTools, mcpServers: mcpServers)
            blocks.append(.text("that tool is disabled for me (**\(label)**). enable it in Settings → Tools."))
            actionToRun = nil
        } else {
            blocks.append(.text(reply.text))
        }

        await applyAction(actionToRun, botId: botId, blocks: &blocks, thread: &thread2, runId: runId)

        let lowerPrompt = prompt.lowercased()
        // OpenMausBot-style approvals for shell wording (file delete is a real home op).
        if lowerPrompt.contains("run shell") {
            let bot = bots.first(where: { $0.id == botId })
            if bot?.isToolEnabled("shell") != true {
                blocks.append(.text("shell is disabled for me. enable it in Settings → Tools."))
            } else {
                let tool = "shell.exec"
                if bot?.autoApprove == true || bot?.alwaysAllowTools.contains(tool) == true {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .alwaysAllowed))
                } else {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .pending))
                }
            }
        }

        if lowerPrompt.contains("choose") || lowerPrompt.contains("pick one") || lowerPrompt.contains("which option") {
            blocks.append(
                .choice(
                    question: "Which should I do?",
                    subtitle: "Pick one to continue",
                    options: [
                        ChoiceOption(id: "a", letter: "A", label: "Continue as planned"),
                        ChoiceOption(id: "b", letter: "B", label: "Try a safer approach"),
                        ChoiceOption(id: "c", letter: "C", label: "Ask me first next time"),
                    ]
                )
            )
        }

        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread2.threadId,
            seq: thread2.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        thread2.messages.append(botMsg)
        thread2.cursor = botMsg.seq

        if case .takeover = actionToRun {
            thread2.run?.status = .waitingTakeover
        } else if case .subagent = actionToRun {
            thread2.run?.status = .running
        } else if blocks.contains(where: {
            if case .approval(_, _, .pending) = $0 { return true }
            if case .choice = $0 { return true }
            return false
        }) {
            thread2.run?.status = .waitingInput
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[threadKey] = thread2

        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            let preview = botMsg.firstText
            bots[idx].preview = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
            if thread2.run?.status.isActive != true && thread2.run?.status != .waitingInput {
                bots[idx].status = "idle"
            }
            bots[idx].updatedAt = .now
            if activeBotId != botId {
                bots[idx].unread = true
            }
        }

        usage.append(
            UsageRecord(
                id: Ids.new(),
                botId: botId,
                runId: runId,
                provider: modelProvider ?? ModelCatalog.defaultProvider,
                model: modelId ?? ModelCatalog.defaultModelId,
                inputTokens: 12,
                outputTokens: 40
            )
        )
        save()

        if case .subagent(let task) = actionToRun {
            await completeSubagent(botId: botId, threadKey: threadKey, runId: runId, messageId: botMsg.id, task: task)
        }

        runTasks.removeValue(forKey: runId)
    }

    private func applyAction(
        _ action: ScriptedAction?,
        botId: String,
        blocks: inout [MessageBlock],
        thread: inout ThreadData,
        runId: String
    ) async {
        guard let action else { return }
        switch action {
        case .spawnBot(let name, let title):
            let child = createBot(
                name: name,
                title: title,
                description: "",
                instructions: "",
                parentBotId: botId
            )
            // createBot selects the child; restore parent as active for the chat context
            activeBotId = botId
            blocks.append(.childBot(botId: child.id, name: child.name, title: child.title, status: .created))

        case .deleteBot(let name):
            if let target = bots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let id = target.id
                let n = target.name
                deleteBot(id)
                blocks.append(.childBot(botId: id, name: n, title: nil, status: .deleted))
            }

        case .subagent(let task):
            blocks.append(
                .subagent(
                    agentId: Ids.new(),
                    name: "helper",
                    task: task,
                    status: .running,
                    progress: "working…",
                    result: nil
                )
            )

        case .takeover:
            if var computer = computers[botId] {
                computer.controlHolder = .user
                computers[botId] = computer
            }

        case .remember(let text):
            upsertMemory(botId: botId, text: text)

        case .writeFile(let path, let content):
            writeBotFile(botId: botId, path: path, content: content)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(.card(lines: [
                CardLine(k: "wrote", v: path),
                CardLine(k: "preview", v: String(trimmed.prefix(240))),
            ]))

        case .readFile(let path):
            do {
                let content = try botHome.read(botId: botId, path: path)
                blocks.append(.card(lines: [
                    CardLine(k: "read", v: path),
                    CardLine(k: "content", v: String(content.prefix(800))),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "read failed", v: error.localizedDescription)]))
            }

        case .editFile(let path, let content, let append):
            do {
                try botHome.edit(
                    botId: botId,
                    path: path,
                    content: content,
                    mode: append ? .append : .replace
                )
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: append ? "appended" : "edited", v: path),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "edit failed", v: error.localizedDescription)]))
            }

        case .moveFile(let from, let to):
            do {
                try botHome.move(botId: botId, from: from, to: to)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: "moved", v: "\(from) → \(to)"),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "move failed", v: error.localizedDescription)]))
            }

        case .deleteFile(let path):
            do {
                try botHome.delete(botId: botId, path: path)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [CardLine(k: "deleted", v: path)]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "delete failed", v: error.localizedDescription)]))
            }

        case .listFiles(let directory):
            do {
                let entries = try botHome.list(botId: botId, directory: directory)
                if entries.isEmpty {
                    blocks.append(.card(lines: [CardLine(k: "home", v: "(empty)")]))
                } else {
                    let lines = entries.prefix(20).map { entry in
                        CardLine(k: entry.isDirectory ? "dir" : "file", v: entry.path)
                    }
                    blocks.append(.card(lines: Array(lines)))
                }
            } catch {
                blocks.append(.card(lines: [CardLine(k: "list failed", v: error.localizedDescription)]))
            }

        case .webSearch(let query):
            do {
                let results = try await WebSearch.search(query: query, limit: 5)
                if results.isEmpty {
                    blocks.append(.card(lines: [
                        CardLine(k: "search", v: query),
                        CardLine(k: "results", v: "no results"),
                    ]))
                } else {
                    var lines = [CardLine(k: "search", v: query)]
                    for (idx, item) in results.enumerated() {
                        lines.append(CardLine(k: "\(idx + 1). \(item.title)", v: item.snippet.isEmpty ? item.url : item.snippet))
                    }
                    blocks.append(.card(lines: lines))
                    blocks.append(.text(results.map { "• **\($0.title)** — \($0.snippet)\n  \($0.url)" }.joined(separator: "\n\n")))
                }
            } catch {
                blocks.append(.card(lines: [
                    CardLine(k: "search failed", v: error.localizedDescription),
                ]))
            }

        case .destinationWrite(let title, _):
            blocks.append(.card(lines: [CardLine(k: title, v: "recorded")]))

        case .customTool(let id, let name):
            if let tool = customTools.first(where: { $0.id == id }) {
                blocks.append(.card(lines: [
                    CardLine(k: "tool", v: name),
                    CardLine(k: "status", v: "completed"),
                ]))
                _ = tool
            } else {
                blocks.append(.card(lines: [CardLine(k: "tool", v: name), CardLine(k: "status", v: "completed")]))
            }

        case .mcpServer(let id, let name, let prompt):
            if let server = mcpServers.first(where: { $0.id == id }) {
                do {
                    let result = try await McpClient.invoke(server: server, prompt: prompt)
                    var lines = [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "tool", v: result.toolName),
                        CardLine(k: "status", v: result.isError ? "tool error" : "ok"),
                    ]
                    switch server.transport {
                    case .stdio:
                        lines.insert(CardLine(k: "command", v: server.summaryLine), at: 2)
                    case .http, .sse:
                        lines.insert(CardLine(k: "url", v: server.summaryLine), at: 2)
                    }
                    blocks.append(.card(lines: lines))
                    let body = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        blocks.append(.text(String(body.prefix(4000))))
                    }
                } catch {
                    blocks.append(.card(lines: [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "status", v: "failed"),
                        CardLine(k: "error", v: error.localizedDescription),
                    ]))
                }
            } else {
                blocks.append(.card(lines: [
                    CardLine(k: "mcp", v: name),
                    CardLine(k: "status", v: "missing"),
                ]))
            }
        }
    }

    private func writeBotFile(botId: String, path: String, content: String) {
        do {
            try botHome.write(botId: botId, path: path, content: content)
        } catch {
            // Fall back to workspace mirror only.
        }
        upsertFile(path: path, content: content)
        refreshFilesMirror(botId: botId)
    }

    private func refreshFilesMirror(botId: String) {
        if let listed = try? botHome.allFilesFlat(botId: botId) {
            files = listed
        }
    }

    public func botHomeEntries(botId: String) -> [BotHomeStore.Entry] {
        (try? botHome.list(botId: botId)) ?? []
    }

    public func readBotHomeFile(botId: String, path: String) -> String? {
        try? botHome.read(botId: botId, path: path)
    }

    private func threadKey(for botId: String) -> String {
        if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
            return taskId
        }
        return botId
    }

    private func completeSubagent(botId: String, threadKey: String, runId: String, messageId: String, task: String) async {
        await sleep(1.5)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey] else { return }
        guard let msgIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var blocks = thread.messages[msgIdx].blocks
        for i in blocks.indices {
            if case .subagent(let agentId, let name, let t, _, _, _) = blocks[i] {
                blocks[i] = .subagent(
                    agentId: agentId,
                    name: name,
                    task: t,
                    status: .completed,
                    progress: nil,
                    result: ScriptedRuntime.subagentResult(for: task)
                )
            }
        }
        thread.messages[msgIdx].blocks = blocks
        thread.run?.status = .completed
        thread.run?.completedAt = .now
        threads[threadKey] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        runTasks.removeValue(forKey: runId)
    }

    private func finishCancelled(botId: String, threadKey: String? = nil, runId: String) {
        let key = threadKey ?? self.threadKey(for: botId)
        guard var thread = threads[key], thread.run?.id == runId else { return }
        thread.messages.removeAll { msg in
            msg.runId == runId && msg.blocks.contains { if case .progress = $0 { return true }; return false }
        }
        thread.run?.status = .cancelled
        thread.run?.completedAt = .now
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        runTasks.removeValue(forKey: runId)
        save()
    }

    public func stopRun(botId: String) {
        let key = threadKey(for: botId)
        guard let runId = threads[key]?.run?.id else { return }
        runTasks[runId]?.cancel()
        finishCancelled(botId: botId, threadKey: key, runId: runId)
    }

    public func answerAsk(botId: String, answer: String = "approved") {
        guard var thread = threads[botId] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text("done — sent.")]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[botId] = thread
        _ = answer
        save()
    }

    private func upsertMemory(botId: String, text: String) {
        let line = "- \(text)\n"
        if let idx = memory.firstIndex(where: { $0.botId == botId && $0.path == "MEMORY.md" }) {
            var doc = memory[idx]
            if !doc.content.contains("# Memory") {
                doc.content = "# Memory\n\n" + doc.content
            }
            doc.content += line
            doc.revision += 1
            doc.updatedAt = .now
            memory[idx] = doc
        } else {
            memory.append(
                MemoryDocument(
                    id: Ids.new(),
                    scope: "bot",
                    botId: botId,
                    path: "MEMORY.md",
                    content: "# Memory\n\n\(line)"
                )
            )
        }
    }

    private func upsertFile(path: String, content: String) {
        if let idx = files.firstIndex(where: { $0.first == path }) {
            files[idx] = [path, content]
        } else {
            files.append([path, content])
        }
    }

    // MARK: - Computer

    public func openPanel(_ panel: Panel?) {
        self.panel = panel
        if panel == .computer, let botId = activeBotId {
            autoBootIfNeeded(botId: botId)
        }
    }

    public func toggleComputerPanel() {
        if panel == .computer {
            panel = nil
        } else {
            openPanel(.computer)
        }
    }

    /// Mirrors rakazo `openComputer`: boot if needed, take control, open full-window overlay.
    public func openComputerOverlay() {
        guard let botId = activeBotId else { return }
        let computer = computers[botId]
        let needsTakeover = computer?.controlHolder != .user
        let needsBoot = computer?.state != .running || computer?.screenAvailable != true
        if needsBoot {
            boot(botId: botId, force: true)
        }
        if needsTakeover {
            takeControl(botId: botId)
        }
        computerOpen = true
        heartbeat(botId: botId)
    }

    public func closeComputerOverlay() {
        computerOpen = false
    }

    private func autoBootIfNeeded(botId: String) {
        guard let computer = computers[botId] else { return }
        if computer.state == .booting || computer.state == .suspended { return }
        if computer.state == .running && computer.screenAvailable { return }
        boot(botId: botId, force: true)
    }

    public func boot(botId: String, force: Bool) {
        guard var computer = computers[botId] else { return }
        if !force, computer.state == .running || computer.state == .booting { return }
        computer.state = .booting
        computer.screenAvailable = false
        computers[botId] = computer
        booting = true
        save()

        bootTasks[botId]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sleep(2.5)
            guard !Task.isCancelled else { return }
            guard var c = self.computers[botId] else { return }
            c.state = .running
            c.screenAvailable = true
            self.computers[botId] = c
            self.booting = false
            self.save()
            self.bootTasks.removeValue(forKey: botId)
        }
        bootTasks[botId] = task
    }

    public func takeControl(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .user
        if computer.state == .suspended {
            computer.state = .running
            computer.screenAvailable = true
        }
        computers[botId] = computer
        save()
    }

    /// Mirrors rakazo `releaseComputer`: release control and close the full-window overlay.
    public func release(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .bot
        computers[botId] = computer
        computerOpen = false
        save()
    }

    /// Keep-alive while the computer panel or overlay is open (rakazo `computer.heartbeat`).
    public func heartbeat(botId: String) {
        guard var computer = computers[botId], computer.state == .running else { return }
        computer.lastHeartbeatAt = .now
        computers[botId] = computer
    }

    // MARK: - Routines

    public func routines(for botId: String) -> [Routine] {
        routines[botId] ?? []
    }

    public func openNewRoutine() {
        editingRoutineId = nil
        routineDraft = RoutineDraft(botId: activeBotId ?? visibleBots.first?.id ?? "")
        panel = .routine
    }

    public func openRoutine(_ routine: Routine) {
        editingRoutineId = routine.id
        routineDraft = RoutineDraft(
            name: routine.name,
            prompt: routine.prompt,
            preset: Cron.preset(fromCron: routine.cron),
            botId: routine.botId
        )
        panel = .routine
    }

    @discardableResult
    public func createRoutine(
        botId: String,
        name: String,
        prompt: String,
        cron: String,
        timezone: String = "UTC",
        active: Bool = true,
        notify: Bool = true
    ) -> Routine {
        let targetBotId = bots.contains(where: { $0.id == botId })
            ? botId
            : (activeBotId ?? bots.first?.id ?? botId)

        // Editing: may reassign to another bot.
        if let editing = editingRoutineId {
            for (ownerId, list) in routines {
                guard let idx = list.firstIndex(where: { $0.id == editing }) else { continue }
                var updated = list[idx]
                updated.name = name
                updated.prompt = prompt
                updated.cron = cron
                updated.timezone = timezone
                updated.active = active
                updated.notify = notify
                updated.nextRunAt = Cron.nextDate(cron, from: .now)
                updated.botId = targetBotId

                if ownerId == targetBotId {
                    var next = list
                    next[idx] = updated
                    routines[ownerId] = next
                } else {
                    var fromList = list
                    fromList.remove(at: idx)
                    routines[ownerId] = fromList
                    var toList = routines[targetBotId] ?? []
                    toList.append(updated)
                    routines[targetBotId] = toList
                }
                save()
                return updated
            }
        }

        let routine = Routine(
            id: Ids.new(),
            botId: targetBotId,
            name: name,
            prompt: prompt,
            cron: cron,
            timezone: timezone,
            active: active,
            notify: notify,
            nextRunAt: Cron.nextDate(cron, from: .now)
        )
        var list = routines[targetBotId] ?? []
        list.append(routine)
        routines[targetBotId] = list
        save()
        return routine
    }

    public func saveRoutineDraft(botId: String? = nil) {
        let assigned = {
            let draftBot = routineDraft.botId
            if !draftBot.isEmpty, bots.contains(where: { $0.id == draftBot }) { return draftBot }
            if let botId, bots.contains(where: { $0.id == botId }) { return botId }
            return activeBotId ?? visibleBots.first?.id ?? ""
        }()
        guard !assigned.isEmpty else { return }

        let name = routineDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routineDraft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = createRoutine(
            botId: assigned,
            name: name.isEmpty ? "Routine" : name,
            prompt: prompt.isEmpty ? "Check in." : prompt,
            cron: Cron.fromPreset(routineDraft.preset)
        )
        editingRoutineId = nil
        panel = .computer
        if activeBotId != assigned {
            selectBot(assigned)
        }
    }

    public func assignRoutine(_ routineId: String, toBotId: String) {
        guard bots.contains(where: { $0.id == toBotId }) else { return }
        for (ownerId, list) in routines {
            guard let idx = list.firstIndex(where: { $0.id == routineId }) else { continue }
            var routine = list[idx]
            routine.botId = toBotId
            if ownerId == toBotId {
                var next = list
                next[idx] = routine
                routines[ownerId] = next
            } else {
                var fromList = list
                fromList.remove(at: idx)
                routines[ownerId] = fromList
                var toList = routines[toBotId] ?? []
                toList.append(routine)
                routines[toBotId] = toList
            }
            save()
            return
        }
    }

    public func deleteRoutine(_ routineId: String) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?.remove(at: idx)
            if editingRoutineId == routineId {
                editingRoutineId = nil
                panel = .computer
            }
            save()
            return
        }
    }

    /// Run a specific routine (OpenMausBot `/api/routines/:id/run`).
    public func runRoutine(_ routineId: String) {
        guard let botId = routines.first(where: { $0.value.contains(where: { $0.id == routineId }) })?.key,
              let routine = routines[botId]?.first(where: { $0.id == routineId }) else { return }
        fireRoutine(botId: botId, routine: routine)
    }

    public func runNow(botId: String) {
        let list = routines[botId] ?? []
        guard let routine = list.first else {
            openNewRoutine()
            return
        }
        fireRoutine(botId: botId, routine: routine)
    }

    private func fireRoutine(botId: String, routine: Routine) {
        selectBot(botId)
        showChat()
        let key = threadKey(for: botId)
        guard var thread = threads[key] ?? threads[botId] else {
            threads[botId] = ThreadData(threadId: bots.first(where: { $0.id == botId })?.threadId ?? Ids.new())
            guard var created = threads[botId] else { return }
            appendRoutineRun(botId: botId, routine: routine, thread: &created, threadKey: botId)
            return
        }
        appendRoutineRun(botId: botId, routine: routine, thread: &thread, threadKey: key)
    }

    private func appendRoutineRun(botId: String, routine: Routine, thread: inout ThreadData, threadKey: String) {
        let meta = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .system,
            blocks: [.meta("Routine '\(routine.name)' fired")]
        )
        thread.messages.append(meta)
        thread.cursor = meta.seq

        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: "routine"
        )
        thread.run = run
        threads[threadKey] = thread

        if let idx = routines[botId]?.firstIndex(where: { $0.id == routine.id }) {
            routines[botId]?[idx].lastRunAt = .now
            routines[botId]?[idx].nextRunAt = Cron.nextDate(routine.cron, from: .now)
        }
        save()

        let runId = run.id
        let prompt = routine.prompt
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: prompt)
        }
        runTasks[runId] = task
    }

    // MARK: - Plugins

    public func connect(slug: String) {
        guard !connectionPending.contains(slug) else { return }
        connectionPending.insert(slug)
        pluginTasks[slug]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sleep(1.2)
            guard !Task.isCancelled else { return }
            if let idx = self.connections.firstIndex(where: { $0.slug == slug }) {
                self.connections[idx].connected = true
            }
            self.connectionPending.remove(slug)
            self.save()
            self.pluginTasks.removeValue(forKey: slug)
        }
        pluginTasks[slug] = task
    }

    public func revoke(slug: String) {
        guard !connectionPending.contains(slug) else { return }
        connectionPending.insert(slug)
        pluginTasks[slug]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sleep(0.8)
            guard !Task.isCancelled else { return }
            if let idx = self.connections.firstIndex(where: { $0.slug == slug }) {
                self.connections[idx].connected = false
            }
            self.connectionPending.remove(slug)
            self.save()
            self.pluginTasks.removeValue(forKey: slug)
        }
        pluginTasks[slug] = task
    }

    // MARK: - Usage / export / deployment

    public func weeklySummary() -> UsageSummary {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = usage.filter { $0.createdAt >= cutoff }
        return UsageSummary(
            inputTokens: recent.reduce(0) { $0 + $1.inputTokens },
            outputTokens: recent.reduce(0) { $0 + $1.outputTokens },
            runs: recent.count
        )
    }

    public func exportManifest(botId: String) -> ExportManifest? {
        guard let bot = bots.first(where: { $0.id == botId }) else { return nil }
        let mem = memory.filter { $0.botId == botId }.map {
            ExportManifest.MemoryEntry(path: $0.path, content: $0.content)
        }
        let rts = (routines[botId] ?? []).map {
            ExportManifest.RoutineExport(name: $0.name, prompt: $0.prompt, cron: $0.cron, timezone: $0.timezone)
        }
        let fileEntries = files.map { ExportManifest.FileEntry(path: $0[0], content: $0.count > 1 ? $0[1] : "") }
        let history = threads[botId]?.messages ?? []
        return ExportManifest(
            bot: .init(
                name: bot.name,
                title: bot.title,
                description: bot.description,
                instructions: bot.instructions
            ),
            memory: mem,
            routines: rts,
            files: fileEntries,
            history: history
        )
    }

    public func setComputerHost(_ host: String) {
        deployment.computerHost = host
        showHostPrompt = false
        save()
    }

    public func exportFilename(for botId: String) -> String {
        let name = bots.first(where: { $0.id == botId })?.name ?? "bot"
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(slug)-export.json"
    }

    // MARK: - Chat / workspace sessions

    public var activeSessionKey: String? {
        if let groupId = activeGroupId { return groupId }
        guard let botId = activeBotId else { return nil }
        return threadKey(for: botId)
    }

    public var activeSessionTitle: String {
        if let groupId = activeGroupId {
            return groups.first(where: { $0.id == groupId })?.name ?? "Room"
        }
        if let bot = activeBot {
            if let taskId = bot.activeTaskId,
               let task = bot.tasks.first(where: { $0.id == taskId }) {
                return "\(bot.name) · \(task.title)"
            }
            return bot.name
        }
        return "Chat"
    }

    public var activeSessionMessageCount: Int {
        guard let key = activeSessionKey else { return 0 }
        return threads[key]?.messages.count ?? 0
    }

    public func clearActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
        }
        let threadId = threads[key]?.threadId ?? Ids.new()
        threads[key] = ThreadData(threadId: threadId)
        if let botId = activeBotId, key == botId, let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].preview = ""
            bots[idx].updatedAt = .now
        }
        if let groupId = activeGroupId, let gIdx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[gIdx].preview = ""
        }
        save()
    }

    /// Same as clear for the main thread; deletes a task thread entirely.
    public func deleteActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
            if let idx = bots.firstIndex(where: { $0.id == botId }),
               bots[idx].activeTaskId == key {
                bots[idx].tasks.removeAll { $0.id == key }
                bots[idx].activeTaskId = nil
                threads.removeValue(forKey: key)
                bots[idx].updatedAt = .now
                save()
                return
            }
        }
        clearActiveChat()
    }

    public func exportActiveChat() -> ChatSessionExport? {
        guard let key = activeSessionKey, let thread = threads[key] else { return nil }
        return ChatSessionExport(
            threadId: thread.threadId,
            title: activeSessionTitle,
            botId: activeGroupId == nil ? activeBotId : nil,
            groupId: activeGroupId,
            messages: thread.messages
        )
    }

    public func exportActiveChatJSON() -> Data? {
        guard let export = exportActiveChat() else { return nil }
        return try? persistence.encodeJSON(export)
    }

    public func exportActiveChatMarkdown() -> String {
        guard let export = exportActiveChat() else { return "" }
        var lines = [
            "# \(export.title)",
            "",
            "_Exported \(ISO8601DateFormatter().string(from: export.exportedAt))_",
            "",
        ]
        for message in export.messages {
            let speaker: String
            switch message.role {
            case .user: speaker = "You"
            case .bot: speaker = export.title
            case .system: speaker = "System"
            }
            let body = message.firstText.isEmpty ? transcriptBody(message) : message.firstText
            lines.append("**\(speaker)**")
            lines.append("")
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func chatExportFilename(json: Bool) -> String {
        let slug = activeSessionTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "·", with: "")
        return json ? "\(slug)-chat.json" : "\(slug)-chat.md"
    }

    public func importChat(_ export: ChatSessionExport) {
        guard let key = activeSessionKey else { return }
        let threadId = threads[key]?.threadId ?? export.threadId
        var thread = ThreadData(threadId: threadId, messages: export.messages)
        thread.cursor = export.messages.map(\.seq).max() ?? -1
        threads[key] = thread
        save()
    }

    @discardableResult
    public func saveWorkspaceSnapshot(name: String? = nil) -> WorkspaceSnapshotMeta? {
        guard let userId = session?.userId else { return nil }
        let ws = currentWorkspace()
        let messageCount = ws.threads.values.reduce(0) { $0 + $1.messages.count }
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        let meta = WorkspaceSnapshotMeta(
            name: {
                let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "Snapshot \(stamp)" : trimmed
            }(),
            botCount: ws.bots.count,
            messageCount: messageCount
        )
        persistence.saveSnapshot(WorkspaceSnapshot(meta: meta, workspace: ws), userId: userId)
        return meta
    }

    public func listWorkspaceSnapshots() -> [WorkspaceSnapshotMeta] {
        guard let userId = session?.userId else { return [] }
        return persistence.listSnapshots(userId: userId)
    }

    @discardableResult
    public func restoreWorkspaceSnapshot(_ id: String) -> Bool {
        guard let userId = session?.userId,
              let snapshot = persistence.loadSnapshot(id: id, userId: userId) else { return false }
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(snapshot.workspace)
        route = bots.isEmpty ? .onboarding : .shell
        save()
        return true
    }

    public func deleteWorkspaceSnapshot(_ id: String) {
        guard let userId = session?.userId else { return }
        persistence.deleteSnapshot(id: id, userId: userId)
    }

    public func exportWorkspaceJSON() -> Data? {
        try? persistence.encodeJSON(currentWorkspace())
    }

    public func workspaceExportFilename() -> String {
        let slug = (session?.name ?? "workspace")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(slug)-workspace.json"
    }

    /// Wipe bots, chats, routines, and files. Keeps the signed-in account.
    public func deleteWorkspace() {
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(UserWorkspace())
        route = .onboarding
        showHostPrompt = false
        save()
    }

    private func transcriptBody(_ message: ThreadMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .meta(let t): return t
            case .ask(let t, _): return t
            case .card(let lines):
                return lines.map { "\($0.k): \($0.v)" }.joined(separator: "\n")
            case .subagent(_, let name, let task, let status, _, let result):
                return "[\(name) \(status.rawValue)] \(task)" + (result.map { " — \($0)" } ?? "")
            case .childBot(_, let name, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .approval(let tool, let detail, let status):
                return "[\(status.rawValue)] \(tool): \(detail)"
            case .choice(let question, _, _):
                return question
            case .connect(let name, _, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .computer(let state, let text):
                return "[\(state)] \(text)"
            case .progress(let t):
                return t
            }
        }.joined(separator: "\n")
    }

    // MARK: - OpenMausBot-inspired surfaces

    public var visibleBots: [Bot] {
        bots.filter { !$0.hidden }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    public func openAppSettings(section: AppSettingsSection = .general) {
        appSettingsSection = section
        appSettingsOpen = true
    }

    public func closeAppSettings() {
        appSettingsOpen = false
    }

    public func saveAppConfig(_ config: AppConfig) {
        appConfig = config
        if var session {
            if !config.profileName.isEmpty { session.name = config.profileName }
            if !config.profileEmail.isEmpty { session.email = config.profileEmail }
            self.session = session
        }
        save()
    }

    public func showRoutinesPage() {
        mainView = .routines
        panel = nil
        activeGroupId = nil
    }

    public func showChat() {
        mainView = .chat
    }

    public func selectGroup(_ groupId: String) {
        activeGroupId = groupId
        activeBotId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].unread = false
            save()
        }
    }

    public func selectBot(_ botId: String) {
        activeBotId = botId
        activeGroupId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].unread = false
            save()
        }
    }

    @discardableResult
    public func duplicateBot(_ botId: String) -> Bot? {
        guard let source = bots.first(where: { $0.id == botId }) else { return nil }
        let copy = createBot(
            name: "\(source.name) copy",
            title: source.title,
            description: source.description,
            instructions: source.instructions,
            parentBotId: source.parentBotId
        )
        if let idx = bots.firstIndex(where: { $0.id == copy.id }) {
            bots[idx].autoApprove = source.autoApprove
            bots[idx].speakReplies = source.speakReplies
            bots[idx].notifications = source.notifications
            bots[idx].computerMode = source.computerMode
            bots[idx].modelProvider = source.modelProvider
            bots[idx].modelId = source.modelId
            bots[idx].enabledTools = source.enabledTools
            save()
            return bots[idx]
        }
        return copy
    }

    public func setBotTool(_ botId: String, toolId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setTool(toolId, enabled: enabled)
        bots[idx].updatedAt = .now
        save()
    }

    public func setAllBotTools(_ botId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setAllTools(enabled: enabled, knownIds: knownToolIds)
        bots[idx].updatedAt = .now
        save()
    }

    public func setDefaultTool(_ toolId: String, enabled: Bool) {
        var tools = appConfig.defaultEnabledTools
        if enabled {
            if !tools.contains(toolId) { tools.append(toolId) }
        } else {
            tools.removeAll { $0 == toolId }
        }
        appConfig.defaultEnabledTools = tools
        save()
    }

    public func setAllDefaultTools(enabled: Bool) {
        appConfig.defaultEnabledTools = enabled ? knownToolIds : []
        save()
    }

    public var knownToolIds: [String] {
        AgentToolCatalog.allIds(custom: customTools, mcpServers: mcpServers)
    }

    public var knownToolDefinitions: [AgentToolDefinition] {
        AgentToolCatalog.definitions(custom: customTools, mcpServers: mcpServers)
    }

    @discardableResult
    public func addMcpServer(
        name: String,
        transport: McpTransport,
        command: String,
        args: [String],
        env: [String: String],
        url: String,
        headers: [String: String]
    ) -> McpServer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let server = McpServer(
            name: trimmed,
            transport: transport,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            args: args,
            env: env,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers
        )
        mcpServers.append(server)
        optInNewTool(server.toolId)
        save()
        return server
    }

    public func updateMcpServer(_ server: McpServer) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        mcpServers[idx] = server
        save()
    }

    public func deleteMcpServer(_ serverId: String) {
        let toolId = mcpServers.first(where: { $0.id == serverId })?.toolId ?? "mcp:\(serverId)"
        mcpServers.removeAll { $0.id == serverId }
        appConfig.defaultEnabledTools.removeAll { $0 == toolId }
        for i in bots.indices {
            bots[i].enabledTools.removeAll { $0 == toolId }
        }
        save()
    }

    private func optInNewTool(_ toolId: String) {
        if !appConfig.defaultEnabledTools.contains(toolId) {
            appConfig.defaultEnabledTools.append(toolId)
        }
        for i in bots.indices {
            if !bots[i].enabledTools.contains(toolId), !bots[i].noToolsEnabled {
                bots[i].enabledTools.append(toolId)
            }
        }
    }

    @discardableResult
    public func addCustomTool(
        name: String,
        description: String,
        triggers: [String],
        responseTemplate: String
    ) -> CustomAgentTool? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let phraseList = triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tool = CustomAgentTool(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            triggers: phraseList.isEmpty ? [trimmed.lowercased()] : phraseList,
            responseTemplate: responseTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ran **{name}** on: {prompt}"
                : responseTemplate
        )
        customTools.append(tool)
        optInNewTool(tool.id)
        save()
        return tool
    }

    public func updateCustomTool(_ tool: CustomAgentTool) {
        guard let idx = customTools.firstIndex(where: { $0.id == tool.id }) else { return }
        customTools[idx] = tool
        save()
    }

    public func deleteCustomTool(_ toolId: String) {
        customTools.removeAll { $0.id == toolId }
        appConfig.defaultEnabledTools.removeAll { $0 == toolId }
        for i in bots.indices {
            bots[i].enabledTools.removeAll { $0 == toolId }
        }
        save()
    }

    public func setBotPinned(_ botId: String, pinned: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].pinned = pinned
        save()
    }

    public func setBotHidden(_ botId: String, hidden: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].hidden = hidden
        if hidden, activeBotId == botId {
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public func markBotUnread(_ botId: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].unread = true
        save()
    }

    public func setChiefOfStaff(_ botId: String, enabled: Bool) {
        for i in bots.indices {
            bots[i].chiefOfStaff = enabled && bots[i].id == botId
        }
        save()
    }

    public func patchBot(
        _ botId: String,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        color: String? = nil,
        autoApprove: Bool? = nil,
        speakReplies: Bool? = nil,
        notifications: Bool? = nil,
        computerMode: ComputerMode? = nil,
        modelProvider: String? = nil,
        modelId: String? = nil
    ) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let name { bots[idx].name = name }
        if let title { bots[idx].title = title }
        if let description { bots[idx].description = description }
        if let instructions { bots[idx].instructions = instructions }
        if let color { bots[idx].color = color }
        if let autoApprove { bots[idx].autoApprove = autoApprove }
        if let speakReplies { bots[idx].speakReplies = speakReplies }
        if let notifications { bots[idx].notifications = notifications }
        if let computerMode { bots[idx].computerMode = computerMode }
        if let modelProvider { bots[idx].modelProvider = modelProvider }
        if let modelId { bots[idx].modelId = modelId }
        bots[idx].updatedAt = .now
        save()
    }

    @discardableResult
    public func createGroup(name: String, memberIds: [String]) -> GroupRoom {
        let members = memberIds.isEmpty ? Array(visibleBots.prefix(2).map(\.id)) : memberIds
        let group = GroupRoom(name: name, memberIds: members)
        groups.append(group)
        threads[group.id] = ThreadData(threadId: group.threadId)
        activeGroupId = group.id
        activeBotId = nil
        mainView = .chat
        save()
        return group
    }

    public func updateGroupBulletin(_ groupId: String, bulletin: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].bulletin = bulletin
        save()
    }

    public func sendGroupMessage(groupId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var thread = threads[groupId] else { return }
        guard let gIdx = groups.firstIndex(where: { $0.id == groupId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(trimmed)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        threads[groupId] = thread
        groups[gIdx].preview = trimmed
        save()

        // Scripted room reply from the first member / everyone.
        let responderId: String? = {
            switch groups[gIdx].defaultResponder {
            case .member(let id): return id
            case .everyone, .mentions:
                return groups[gIdx].memberIds.first
            }
        }()
        let reply = ScriptedRuntime.reply(to: trimmed, customTools: customTools, mcpServers: mcpServers)
        let name = bots.first(where: { $0.id == responderId })?.name ?? "Room"
        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq + 1,
            role: .bot,
            blocks: [.text("**\(name):** \(reply.text)")]
        )
        var t2 = threads[groupId] ?? thread
        t2.messages.append(botMsg)
        t2.cursor = botMsg.seq
        threads[groupId] = t2
        groups[gIdx].preview = botMsg.firstText
        save()
    }

    @discardableResult
    public func createTask(botId: String, title: String) -> BotTask? {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return nil }
        let task = BotTask(title: title.isEmpty ? "New task" : title)
        bots[idx].tasks.append(task)
        bots[idx].activeTaskId = task.id
        threads[task.id] = ThreadData(threadId: task.threadId)
        // Point bot.threadId at the task thread for chat routing.
        bots[idx].threadId = task.threadId
        if threads[botId] == nil {
            threads[botId] = ThreadData(threadId: bots[idx].threadId)
        }
        save()
        return task
    }

    public func selectTask(botId: String, taskId: String?) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let taskId, let task = bots[idx].tasks.first(where: { $0.id == taskId }) {
            bots[idx].activeTaskId = taskId
            bots[idx].threadId = task.threadId
            if threads[taskId] == nil {
                threads[taskId] = ThreadData(threadId: task.threadId)
            }
        } else {
            bots[idx].activeTaskId = nil
        }
        save()
    }

    public func messagesForActiveContext(botId: String) -> [ThreadMessage] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        if let taskId = bot.activeTaskId {
            return threads[taskId]?.messages ?? []
        }
        return threads[botId]?.messages ?? []
    }

    public func toggleReaction(botId: String, messageId: String, emoji: String) {
        let key: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var reactions = thread.messages[mIdx].reactions
        if let rIdx = reactions.firstIndex(where: { $0.emoji == emoji }) {
            reactions[rIdx].count += 1
            if reactions[rIdx].count > 3 {
                reactions.remove(at: rIdx)
            }
        } else {
            reactions.append(MessageReaction(emoji: emoji))
        }
        thread.messages[mIdx].reactions = reactions
        threads[key] = thread
        save()
    }

    public func answerApproval(botId: String, messageId: String, decision: ApprovalDecision) {
        let key = threadKey(for: botId)
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        for i in thread.messages[mIdx].blocks.indices {
            if case .approval(let tool, let detail, _) = thread.messages[mIdx].blocks[i] {
                let status: ApprovalStatus
                switch decision {
                case .allow: status = .allowed
                case .deny: status = .denied
                case .alwaysAllow:
                    status = .alwaysAllowed
                    if let bIdx = bots.firstIndex(where: { $0.id == botId }) {
                        if !bots[bIdx].alwaysAllowTools.contains(tool) {
                            bots[bIdx].alwaysAllowTools.append(tool)
                        }
                    }
                }
                thread.messages[mIdx].blocks[i] = .approval(tool: tool, detail: detail, status: status)
            }
        }
        let follow = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text(decision == .deny ? "okay — cancelled." : "okay — proceeding.")]
        )
        thread.messages.append(follow)
        thread.cursor = follow.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
    }

    public func answerChoice(botId: String, messageId: String, option: ChoiceOption) {
        let key = threadKey(for: botId)
        guard var thread = threads[key] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(option.label)]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        threads[key] = thread
        save()
        send(botId: botId, text: option.label)
        _ = messageId
    }

    public func regenerateLast(botId: String) {
        let key = threadKey(for: botId)
        guard let thread = threads[key] else { return }
        guard let lastUser = thread.messages.last(where: { $0.role == .user }) else { return }
        send(botId: botId, text: lastUser.firstText)
    }

    public func deleteGroup(_ groupId: String) {
        groups.removeAll { $0.id == groupId }
        threads.removeValue(forKey: groupId)
        if activeGroupId == groupId {
            activeGroupId = nil
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public var allRoutines: [Routine] {
        routines.values.flatMap { $0 }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    public func setRoutineActive(_ routineId: String, active: Bool) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?[idx].active = active
            save()
            return
        }
    }

    public func setDraft(threadKey: String, text: String) {
        composerDrafts[threadKey] = text
    }

    public func draft(for threadKey: String) -> String {
        composerDrafts[threadKey] ?? ""
    }

    public func selectBotByIndex(_ index: Int) {
        let list = visibleBots
        guard list.indices.contains(index) else { return }
        selectBot(list[index].id)
    }

    public func selectAdjacentBot(delta: Int) {
        let list = visibleBots
        guard !list.isEmpty else { return }
        let current = list.firstIndex(where: { $0.id == activeBotId }) ?? 0
        let next = (current + delta + list.count) % list.count
        selectBot(list[next].id)
    }

    public var missedRoutineCount: Int {
        routines.values.flatMap { $0 }.filter { routine in
            guard let next = routine.nextRunAt else { return false }
            return routine.active && next < Date.now.addingTimeInterval(-12 * 3600)
        }.count
    }
}
