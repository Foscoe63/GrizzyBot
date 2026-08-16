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
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var bootTasks: [String: Task<Void, Never>] = [:]
    private var pluginTasks: [String: Task<Void, Never>] = [:]

    /// Shorter delays in tests so `swift test` stays fast.
    public var delayScale: Double = 1.0

    public struct RoutineDraft: Sendable, Equatable {
        public var name: String = ""
        public var prompt: String = ""
        public var preset: Cron.Preset = Cron.defaultPreset()

        public init(name: String = "", prompt: String = "", preset: Cron.Preset = Cron.defaultPreset()) {
            self.name = name
            self.prompt = prompt
            self.preset = preset
        }
    }

    public init(dataDirectory: URL? = nil, delayScale: Double = 1.0) {
        self.persistence = Persistence(root: dataDirectory)
        self.delayScale = delayScale
        bootstrap()
    }

    // MARK: - Bootstrap

    private func bootstrap() {
        users = persistence.loadUsers()
        if let session = persistence.loadSession(),
           users.contains(where: { $0.id == session.userId }) {
            self.session = session
            loadWorkspace(for: session.userId)
            route = bots.isEmpty ? .onboarding : .shell
            if route == .shell, deployment.computerHost == nil {
                showHostPrompt = true
            }
        } else {
            session = nil
            route = .welcome
        }
    }

    private func loadWorkspace(for userId: String) {
        let ws = persistence.loadWorkspace(userId: userId)
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
        activeBotId = bots.first?.id
    }

    private func save() {
        guard let userId = session?.userId else { return }
        let ws = UserWorkspace(
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
            apiKey: apiKey
        )
        persistence.saveWorkspace(ws, userId: userId)
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
        session = nil
        bots = []
        threads = [:]
        routines = [:]
        computers = [:]
        connections = ConnectionCatalog.defaults
        usage = []
        memory = []
        files = []
        deployment = DeploymentSettings()
        panel = nil
        computerOpen = false
        booting = false
        pluginsOpen = false
        showHostPrompt = false
        activeBotId = nil
        persistence.saveSession(nil)
        route = .welcome
    }

    public func saveModelSelection(provider: String, modelId: String, apiKey: String?) {
        self.modelProvider = provider
        self.modelId = modelId
        self.apiKey = apiKey
        save()
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
        guard let id = activeBotId else { return bots.first }
        return bots.first(where: { $0.id == id }) ?? bots.first
    }

    public func selectBot(_ botId: String) {
        activeBotId = botId
        panel = nil
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
            threadId: threadId
        )
        bots.append(bot)
        threads[bot.id] = ThreadData(threadId: threadId)
        computers[bot.id] = ComputerStatus(
            botId: bot.id,
            kind: deployment.sandboxKind,
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
        threads[botId]?.messages ?? []
    }

    public func isRunActive(botId: String) -> Bool {
        threads[botId]?.run?.status.isActive == true
    }

    public func send(botId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var thread = threads[botId] else { return }
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
        threads[botId] = thread
        bots[botIdx].status = "working"
        bots[botIdx].preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        bots[botIdx].updatedAt = .now
        save()

        let runId = run.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, runId: runId, prompt: trimmed)
        }
        runTasks[runId] = task
    }

    private func runAgent(botId: String, runId: String, prompt: String) async {
        await sleep(0.9)
        guard !Task.isCancelled else { return }
        guard var thread = threads[botId], thread.run?.id == runId else { return }

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
        threads[botId] = thread

        await sleep(0.7)
        guard !Task.isCancelled else {
            await MainActor.run { self.finishCancelled(botId: botId, runId: runId) }
            return
        }
        guard var thread2 = threads[botId], thread2.run?.id == runId else { return }

        // Remove progress bubble
        thread2.messages.removeAll { $0.id == progressMsg.id }

        let reply = ScriptedRuntime.reply(to: prompt)
        var blocks: [MessageBlock] = [.text(reply.text)]
        applyAction(reply.action, botId: botId, blocks: &blocks, thread: &thread2, runId: runId)

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

        if case .takeover = reply.action {
            thread2.run?.status = .waitingTakeover
        } else if case .subagent = reply.action {
            thread2.run?.status = .running
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[botId] = thread2

        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            let preview = botMsg.firstText
            bots[idx].preview = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
            if thread2.run?.status.isActive != true {
                bots[idx].status = "idle"
            }
            bots[idx].updatedAt = .now
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

        if case .subagent(let task) = reply.action {
            await completeSubagent(botId: botId, runId: runId, messageId: botMsg.id, task: task)
        }

        runTasks.removeValue(forKey: runId)
    }

    private func applyAction(
        _ action: ScriptedAction?,
        botId: String,
        blocks: inout [MessageBlock],
        thread: inout ThreadData,
        runId: String
    ) {
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
            upsertFile(path: path, content: content)
            // Card only for the explicit write-note branch (not the default last-task.md write).
            if path == "notes/result.txt" {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(.card(lines: [CardLine(k: path, v: trimmed)]))
            }

        case .destinationWrite(let title, _):
            blocks.append(.card(lines: [CardLine(k: title, v: "recorded")]))
        }
    }

    private func completeSubagent(botId: String, runId: String, messageId: String, task: String) async {
        await sleep(1.5)
        guard !Task.isCancelled else { return }
        guard var thread = threads[botId] else { return }
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
        threads[botId] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        runTasks.removeValue(forKey: runId)
    }

    private func finishCancelled(botId: String, runId: String) {
        guard var thread = threads[botId], thread.run?.id == runId else { return }
        thread.messages.removeAll { msg in
            msg.runId == runId && msg.blocks.contains { if case .progress = $0 { return true }; return false }
        }
        thread.run?.status = .cancelled
        thread.run?.completedAt = .now
        threads[botId] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        runTasks.removeValue(forKey: runId)
        save()
    }

    public func stopRun(botId: String) {
        guard let runId = threads[botId]?.run?.id else { return }
        runTasks[runId]?.cancel()
        finishCancelled(botId: botId, runId: runId)
    }

    public func answerAsk(botId: String, answer: String = "Send it") {
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

    public func openComputerOverlay() {
        computerOpen = true
        if let botId = activeBotId {
            autoBootIfNeeded(botId: botId)
        }
    }

    public func closeComputerOverlay() {
        computerOpen = false
    }

    private func autoBootIfNeeded(botId: String) {
        guard let computer = computers[botId], computer.state == .stopped else { return }
        boot(botId: botId, force: false)
    }

    public func boot(botId: String, force: Bool) {
        guard var computer = computers[botId] else { return }
        if !force, computer.state == .running || computer.state == .booting { return }
        computer.state = .booting
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
        }
        computers[botId] = computer
        save()
    }

    public func release(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .bot
        computers[botId] = computer
        save()
    }

    // MARK: - Routines

    public func routines(for botId: String) -> [Routine] {
        routines[botId] ?? []
    }

    public func openNewRoutine() {
        editingRoutineId = nil
        routineDraft = RoutineDraft()
        panel = .routine
    }

    public func openRoutine(_ routine: Routine) {
        editingRoutineId = routine.id
        routineDraft = RoutineDraft(
            name: routine.name,
            prompt: routine.prompt,
            preset: Cron.preset(fromCron: routine.cron)
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
        let routine = Routine(
            id: Ids.new(),
            botId: botId,
            name: name,
            prompt: prompt,
            cron: cron,
            timezone: timezone,
            active: active,
            notify: notify,
            nextRunAt: Cron.nextDate(cron, from: .now)
        )
        var list = routines[botId] ?? []
        if let editing = editingRoutineId, let idx = list.firstIndex(where: { $0.id == editing }) {
            var updated = list[idx]
            updated.name = name
            updated.prompt = prompt
            updated.cron = cron
            updated.timezone = timezone
            updated.active = active
            updated.notify = notify
            updated.nextRunAt = Cron.nextDate(cron, from: .now)
            list[idx] = updated
            routines[botId] = list
            save()
            return updated
        }
        list.append(routine)
        routines[botId] = list
        save()
        return routine
    }

    public func saveRoutineDraft(botId: String) {
        let name = routineDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routineDraft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = createRoutine(
            botId: botId,
            name: name.isEmpty ? "Routine" : name,
            prompt: prompt.isEmpty ? "Check in." : prompt,
            cron: Cron.fromPreset(routineDraft.preset)
        )
        panel = .computer
    }

    public func runNow(botId: String) {
        let list = routines[botId] ?? []
        guard let routine = list.first else {
            openNewRoutine()
            return
        }
        guard var thread = threads[botId] else { return }

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
        threads[botId] = thread
        save()

        let runId = run.id
        let prompt = routine.prompt
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, runId: runId, prompt: prompt)
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
}
