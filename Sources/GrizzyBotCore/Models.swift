import Foundation

// MARK: - Bot colors (rakazo `BOT_COLORS`)

public let botColors: [String] = [
    "#3EC5A8",
    "#F5A03C",
    "#6A6BF5",
    "#9B5CF6",
    "#3B82F6",
    "#F2622A",
    "#D9508A",
]

// MARK: - Bot (rakazo `BotSchema`)

public struct Bot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var instructions: String
    public var color: String
    public var notifyOnFinish: Bool
    public var parentBotId: String?
    public var threadId: String
    public var preview: String
    public var status: String
    public var updatedAt: Date
    public var createdAt: Date
    // OpenMausBot-inspired roster / settings fields
    public var pinned: Bool
    public var hidden: Bool
    public var unread: Bool
    public var autoApprove: Bool
    public var speakReplies: Bool
    public var notifications: Bool
    public var chiefOfStaff: Bool
    public var computerMode: ComputerMode
    public var modelProvider: String?
    public var modelId: String?
    public var tasks: [BotTask]
    public var activeTaskId: String?
    public var alwaysAllowTools: [String]
    /// Tools this bot is allowed to use. Missing on decode → all tools enabled.
    public var enabledTools: [String]
    /// Skills this bot may load. Missing on decode → all bundled skills.
    public var enabledSkills: [String]
    /// Private bots stay off group pickers. Shared bots can join rooms.
    public var visibility: BotVisibility
    /// Local loop (default) or an AG-UI HTTP endpoint.
    public var runtime: BotRuntime
    public var aguiURL: String?
    public var enabledComponents: [String]

    public init(
        id: String,
        name: String,
        title: String = "",
        description: String = "",
        instructions: String = "",
        color: String,
        notifyOnFinish: Bool = true,
        parentBotId: String? = nil,
        threadId: String,
        preview: String = "",
        status: String = "idle",
        updatedAt: Date = .now,
        createdAt: Date = .now,
        pinned: Bool = false,
        hidden: Bool = false,
        unread: Bool = false,
        autoApprove: Bool = false,
        speakReplies: Bool = false,
        notifications: Bool = true,
        chiefOfStaff: Bool = false,
        computerMode: ComputerMode = .auto,
        modelProvider: String? = nil,
        modelId: String? = nil,
        tasks: [BotTask] = [],
        activeTaskId: String? = nil,
        alwaysAllowTools: [String] = [],
        enabledTools: [String] = AgentToolCatalog.allIds,
        enabledSkills: [String] = BundledSkills.ids,
        visibility: BotVisibility = .private,
        runtime: BotRuntime = .local,
        aguiURL: String? = nil,
        enabledComponents: [String] = AgentComponentCatalog.allIds
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.instructions = instructions
        self.color = color
        self.notifyOnFinish = notifyOnFinish
        self.parentBotId = parentBotId
        self.threadId = threadId
        self.preview = preview
        self.status = status
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.pinned = pinned
        self.hidden = hidden
        self.unread = unread
        self.autoApprove = autoApprove
        self.speakReplies = speakReplies
        self.notifications = notifications
        self.chiefOfStaff = chiefOfStaff
        self.computerMode = computerMode
        self.modelProvider = modelProvider
        self.modelId = modelId
        self.tasks = tasks
        self.activeTaskId = activeTaskId
        self.alwaysAllowTools = alwaysAllowTools
        self.enabledTools = enabledTools
        self.enabledSkills = enabledSkills
        self.visibility = visibility
        self.runtime = runtime
        self.aguiURL = aguiURL
        self.enabledComponents = enabledComponents
    }

    enum CodingKeys: String, CodingKey {
        case id, name, title, description, instructions, color, notifyOnFinish, parentBotId
        case threadId, preview, status, updatedAt, createdAt
        case pinned, hidden, unread, autoApprove, speakReplies, notifications, chiefOfStaff
        case computerMode, modelProvider, modelId, tasks, activeTaskId, alwaysAllowTools
        case enabledTools, enabledSkills, visibility, runtime, aguiURL, enabledComponents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        color = try c.decode(String.self, forKey: .color)
        notifyOnFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? true
        parentBotId = try c.decodeIfPresent(String.self, forKey: .parentBotId)
        threadId = try c.decode(String.self, forKey: .threadId)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? false
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        chiefOfStaff = try c.decodeIfPresent(Bool.self, forKey: .chiefOfStaff) ?? false
        computerMode = try c.decodeIfPresent(ComputerMode.self, forKey: .computerMode) ?? .auto
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        tasks = try c.decodeIfPresent([BotTask].self, forKey: .tasks) ?? []
        activeTaskId = try c.decodeIfPresent(String.self, forKey: .activeTaskId)
        alwaysAllowTools = try c.decodeIfPresent([String].self, forKey: .alwaysAllowTools) ?? []
        enabledTools = try c.decodeIfPresent([String].self, forKey: .enabledTools) ?? AgentToolCatalog.allIds
        enabledSkills = try c.decodeIfPresent([String].self, forKey: .enabledSkills) ?? BundledSkills.ids
        visibility = try c.decodeIfPresent(BotVisibility.self, forKey: .visibility) ?? .private
        runtime = try c.decodeIfPresent(BotRuntime.self, forKey: .runtime) ?? .local
        aguiURL = try c.decodeIfPresent(String.self, forKey: .aguiURL)
        enabledComponents = try c.decodeIfPresent([String].self, forKey: .enabledComponents) ?? AgentComponentCatalog.allIds
    }
}

// MARK: - Message blocks (rakazo `MessageBlock` discriminated union)

public struct CardLine: Codable, Sendable, Hashable {
    public var k: String
    public var v: String

    public init(k: String, v: String) {
        self.k = k
        self.v = v
    }
}

public struct ChoiceOption: Codable, Sendable, Hashable {
    public var id: String
    public var letter: String
    public var label: String

    public init(id: String, letter: String, label: String) {
        self.id = id
        self.letter = letter
        self.label = label
    }
}

public enum SubagentStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
}

public enum ChildBotStatus: String, Codable, Sendable {
    case created
    case deleted
}

public enum ConnectStatus: String, Codable, Sendable {
    case pending
    case connected
}

public enum MessageBlock: Codable, Sendable, Hashable {
    case text(String)
    case card(lines: [CardLine])
    case ask(text: String, detail: String?)
    case choice(question: String, subtitle: String?, options: [ChoiceOption])
    case connect(name: String, initial: String, color: String, status: ConnectStatus)
    case computer(state: String, text: String)
    case meta(String)
    case progress(String)
    case subagent(
        agentId: String,
        name: String,
        task: String,
        status: SubagentStatus,
        progress: String?,
        result: String?
    )
    case childBot(botId: String, name: String, title: String?, status: ChildBotStatus)
    case approval(tool: String, detail: String, status: ApprovalStatus)
    case component(ComponentPayload)
}

public enum ApprovalStatus: String, Codable, Sendable {
    case pending
    case allowed
    case denied
    case alwaysAllowed = "always_allowed"
}

// MARK: - Thread message (rakazo `ThreadMessageSchema`)

public enum MessageRole: String, Codable, Sendable {
    case user
    case bot
    case system
}

public struct ThreadMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var threadId: String
    public var seq: Int
    public var role: MessageRole
    public var blocks: [MessageBlock]
    public var runId: String?
    public var createdAt: Date
    public var reactions: [MessageReaction]

    public init(
        id: String,
        threadId: String,
        seq: Int,
        role: MessageRole,
        blocks: [MessageBlock],
        runId: String? = nil,
        createdAt: Date = .now,
        reactions: [MessageReaction] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.seq = seq
        self.role = role
        self.blocks = blocks
        self.runId = runId
        self.createdAt = createdAt
        self.reactions = reactions
    }

    enum CodingKeys: String, CodingKey {
        case id, threadId, seq, role, blocks, runId, createdAt, reactions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        seq = try c.decode(Int.self, forKey: .seq)
        role = try c.decode(MessageRole.self, forKey: .role)
        blocks = try c.decode([MessageBlock].self, forKey: .blocks)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        reactions = try c.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
    }

    /// First plain-text content, used for the sidebar preview.
    public var firstText: String {
        for block in blocks {
            if case .text(let t) = block, !t.isEmpty { return t }
            if case .component(let payload) = block, !payload.title.isEmpty { return payload.title }
        }
        return ""
    }
}

// MARK: - Run (rakazo `RunSchema` / `RunStatus`)

public enum RunStatus: String, Codable, Sendable {
    case queued
    case leased
    case running
    case waitingInput = "waiting_input"
    case waitingTakeover = "waiting_takeover"
    case completed
    case failed
    case cancelled

    /// The UI shows the "working…" pulse for these states.
    public var isActive: Bool {
        switch self {
        case .queued, .leased, .running: return true
        default: return false
        }
    }
}

public struct Run: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var botId: String
    public var threadId: String
    public var status: RunStatus
    public var trigger: String
    public var modelProvider: String?
    public var modelId: String?
    public var error: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var routineId: String?

    public init(
        id: String,
        botId: String,
        threadId: String,
        status: RunStatus = .running,
        trigger: String = "user",
        modelProvider: String? = nil,
        modelId: String? = nil,
        error: String? = nil,
        startedAt: Date? = .now,
        completedAt: Date? = nil,
        routineId: String? = nil
    ) {
        self.id = id
        self.botId = botId
        self.threadId = threadId
        self.status = status
        self.trigger = trigger
        self.modelProvider = modelProvider
        self.modelId = modelId
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.routineId = routineId
    }
}

// MARK: - Computer (rakazo `ComputerStatusSchema` / `SandboxKind`)

public enum SandboxKind: String, Sendable {
    case browser
    case desktop
    case none
}

extension SandboxKind: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "desktop", "local": self = .desktop
        case "none", "off", "fake": self = .none
        default: self = .browser
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ComputerState: String, Codable, Sendable {
    case stopped
    case booting
    case running
    case suspended
    case error
}

public enum ControlHolder: String, Codable, Sendable {
    case bot
    case user
    case none
}

public struct ComputerStatus: Codable, Sendable, Hashable {
    public var botId: String
    public var kind: SandboxKind
    public var state: ComputerState
    public var controlHolder: ControlHolder
    public var screenAvailable: Bool
    public var lastHeartbeatAt: Date?
    /// Last screenshot outline. Click policy hit-tests this, not the model's claimed label.
    public var lastOutline: String
    public var lastPageURL: String
    public var lastElement: PolicyElement?

    public init(
        botId: String,
        kind: SandboxKind = .browser,
        state: ComputerState = .stopped,
        controlHolder: ControlHolder = .none,
        screenAvailable: Bool = false,
        lastHeartbeatAt: Date? = nil,
        lastOutline: String = "",
        lastPageURL: String = "",
        lastElement: PolicyElement? = nil
    ) {
        self.botId = botId
        self.kind = kind
        self.state = state
        self.controlHolder = controlHolder
        self.screenAvailable = screenAvailable
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastOutline = lastOutline
        self.lastPageURL = lastPageURL
        self.lastElement = lastElement
    }

    enum CodingKeys: String, CodingKey {
        case botId, kind, state, controlHolder, screenAvailable, lastHeartbeatAt
        case lastOutline, lastPageURL, lastElement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botId = try c.decode(String.self, forKey: .botId)
        kind = try c.decodeIfPresent(SandboxKind.self, forKey: .kind) ?? .browser
        state = try c.decodeIfPresent(ComputerState.self, forKey: .state) ?? .stopped
        controlHolder = try c.decodeIfPresent(ControlHolder.self, forKey: .controlHolder) ?? .none
        screenAvailable = try c.decodeIfPresent(Bool.self, forKey: .screenAvailable) ?? false
        lastHeartbeatAt = try c.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt)
        lastOutline = try c.decodeIfPresent(String.self, forKey: .lastOutline) ?? ""
        lastPageURL = try c.decodeIfPresent(String.self, forKey: .lastPageURL) ?? ""
        lastElement = try c.decodeIfPresent(PolicyElement.self, forKey: .lastElement)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(botId, forKey: .botId)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encode(controlHolder, forKey: .controlHolder)
        try c.encode(screenAvailable, forKey: .screenAvailable)
        try c.encodeIfPresent(lastHeartbeatAt, forKey: .lastHeartbeatAt)
        try c.encode(lastOutline, forKey: .lastOutline)
        try c.encode(lastPageURL, forKey: .lastPageURL)
        try c.encodeIfPresent(lastElement, forKey: .lastElement)
    }
}

// MARK: - Routine (rakazo `RoutineSchema`)

public struct Routine: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var botId: String
    public var name: String
    public var prompt: String
    public var cron: String
    public var timezone: String
    public var active: Bool
    public var notify: Bool
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var createdAt: Date
    public var inProgress: Bool
    public var failCount: Int
    public var lastError: String?

    public init(
        id: String,
        botId: String,
        name: String,
        prompt: String,
        cron: String,
        timezone: String = "UTC",
        active: Bool = true,
        notify: Bool = true,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        createdAt: Date = .now,
        inProgress: Bool = false,
        failCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.botId = botId
        self.name = name
        self.prompt = prompt
        self.cron = cron
        self.timezone = timezone
        self.active = active
        self.notify = notify
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.inProgress = inProgress
        self.failCount = failCount
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id, botId, name, prompt, cron, timezone, active, notify
        case lastRunAt, nextRunAt, createdAt, inProgress, failCount, lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        botId = try c.decode(String.self, forKey: .botId)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        cron = try c.decode(String.self, forKey: .cron)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        inProgress = try c.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
        failCount = try c.decodeIfPresent(Int.self, forKey: .failCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

// MARK: - Plugins / connections (rakazo `ConnectionCatalogItemSchema`)

public struct ConnectionItem: Codable, Sendable, Hashable, Identifiable {
    public var slug: String
    public var name: String
    public var logo: String?
    public var connected: Bool
    public var noAuth: Bool
    public var accountLabel: String?
    public var tokenHint: String?
    public var blurb: String
    public var domain: String?
    public var viaComposio: Bool

    public var id: String { slug }

    public var faviconURL: URL? {
        guard let domain, !domain.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")
    }

    public init(
        slug: String,
        name: String,
        logo: String? = nil,
        connected: Bool = false,
        noAuth: Bool = false,
        accountLabel: String? = nil,
        tokenHint: String? = nil,
        blurb: String = "",
        domain: String? = nil,
        viaComposio: Bool = false
    ) {
        self.slug = slug
        self.name = name
        self.logo = logo
        self.connected = connected
        self.noAuth = noAuth
        self.accountLabel = accountLabel
        self.tokenHint = tokenHint
        self.blurb = blurb
        self.domain = domain
        self.viaComposio = viaComposio
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, logo, connected, noAuth, accountLabel, tokenHint, blurb, domain, viaComposio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        noAuth = try c.decodeIfPresent(Bool.self, forKey: .noAuth) ?? false
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        tokenHint = try c.decodeIfPresent(String.self, forKey: .tokenHint)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        viaComposio = try c.decodeIfPresent(Bool.self, forKey: .viaComposio) ?? false
    }
}

// MARK: - Usage (rakazo `UsageRecordSchema`)

public struct UsageRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var botId: String?
    public var runId: String?
    public var provider: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var createdAt: Date

    public init(
        id: String,
        botId: String? = nil,
        runId: String? = nil,
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.botId = botId
        self.runId = runId
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.createdAt = createdAt
    }
}

public struct UsageSummary: Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var runs: Int

    public init(inputTokens: Int, outputTokens: Int, runs: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.runs = runs
    }
}

// MARK: - Memory (rakazo `MemoryDocumentSchema`)

public struct MemoryDocument: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var scope: String
    public var botId: String?
    public var path: String
    public var content: String
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: String,
        scope: String = "bot",
        botId: String? = nil,
        path: String,
        content: String,
        revision: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.scope = scope
        self.botId = botId
        self.path = path
        self.content = content
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

// MARK: - Export manifest (rakazo `ExportManifestSchema`)

public struct ExportManifest: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var bot: BotExport
    public var memory: [MemoryEntry]
    public var routines: [RoutineExport]
    public var files: [FileEntry]
    public var history: [ThreadMessage]

    public struct BotExport: Codable, Sendable {
        public var name: String
        public var title: String
        public var description: String
        public var instructions: String

        public init(name: String, title: String, description: String, instructions: String) {
            self.name = name
            self.title = title
            self.description = description
            self.instructions = instructions
        }
    }

    public struct MemoryEntry: Codable, Sendable {
        public var path: String
        public var content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    public struct RoutineExport: Codable, Sendable {
        public var name: String
        public var prompt: String
        public var cron: String
        public var timezone: String

        public init(name: String, prompt: String, cron: String, timezone: String) {
            self.name = name
            self.prompt = prompt
            self.cron = cron
            self.timezone = timezone
        }
    }

    public struct FileEntry: Codable, Sendable {
        public var path: String
        public var content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    public func redacted() -> ExportManifest {
        ExportManifest(
            version: version,
            exportedAt: exportedAt,
            bot: bot,
            memory: memory.map { MemoryEntry(path: $0.path, content: DiagnosticScrubber.redact($0.content)) },
            routines: routines,
            files: files.map { FileEntry(path: $0.path, content: DiagnosticScrubber.redact($0.content)) },
            history: []
        )
    }

    public init(
        version: Int = 1,
        exportedAt: Date = .now,
        bot: BotExport,
        memory: [MemoryEntry],
        routines: [RoutineExport],
        files: [FileEntry],
        history: [ThreadMessage]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.bot = bot
        self.memory = memory
        self.routines = routines
        self.files = files
        self.history = history
    }
}

/// Chat-only export (current thread), distinct from a full bot manifest.
public struct ChatSessionExport: Codable, Sendable {
    public var version: Int
    public var kind: String
    public var exportedAt: Date
    public var threadId: String
    public var title: String
    public var botId: String?
    public var groupId: String?
    public var messages: [ThreadMessage]

    public init(
        version: Int = 1,
        kind: String = "chat",
        exportedAt: Date = .now,
        threadId: String,
        title: String,
        botId: String? = nil,
        groupId: String? = nil,
        messages: [ThreadMessage]
    ) {
        self.version = version
        self.kind = kind
        self.exportedAt = exportedAt
        self.threadId = threadId
        self.title = title
        self.botId = botId
        self.groupId = groupId
        self.messages = messages
    }
}

/// Named workspace snapshot stored under Application Support.
public struct WorkspaceSnapshotMeta: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var savedAt: Date
    public var botCount: Int
    public var messageCount: Int

    public init(
        id: String = Ids.new(),
        name: String,
        savedAt: Date = .now,
        botCount: Int = 0,
        messageCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.botCount = botCount
        self.messageCount = messageCount
    }
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var meta: WorkspaceSnapshotMeta
    public var workspace: UserWorkspace

    public init(meta: WorkspaceSnapshotMeta, workspace: UserWorkspace) {
        self.meta = meta
        self.workspace = workspace
    }
}

// MARK: - User / session (rakazo `MeSchema`)

public struct UserAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var email: String
    public var name: String
    public var createdAt: Date
    public var role: AccountRole

    public init(id: String, email: String, name: String, createdAt: Date = .now, role: AccountRole = .owner) {
        self.id = id
        self.email = email
        self.name = name
        self.createdAt = createdAt
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case id, email, name, createdAt, passwordHash, role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        role = try c.decodeIfPresent(AccountRole.self, forKey: .role) ?? .owner
        if let legacyHash = try c.decodeIfPresent(String.self, forKey: .passwordHash),
           !legacyHash.isEmpty {
            try? AccountCredentialStore.save(userId: id, passwordHash: legacyHash)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(role, forKey: .role)
    }
}

public struct Session: Codable, Sendable {
    public var userId: String
    public var name: String
    public var email: String

    public init(userId: String, name: String, email: String) {
        self.userId = userId
        self.name = name
        self.email = email
    }

    public var initials: String {
        let parts = name.split(separator: " ").map { $0.first.map(String.init) ?? "" }
        return parts.joined().prefix(2).uppercased()
    }
}

// MARK: - Deployment settings (rakazo `DeploymentSettingsSchema`)

public struct DeploymentSettings: Codable, Sendable {
    /// `in-app-browser` (persistent WKWebView) or `this-mac`. Legacy `docker` maps to in-app browser.
    public var computerHost: String?
    public var canChooseHostComputer: Bool

    public init(computerHost: String? = nil, canChooseHostComputer: Bool = true) {
        self.computerHost = computerHost
        self.canChooseHostComputer = canChooseHostComputer
    }

    public var normalizedHost: ComputerHost? {
        ComputerHost.normalize(computerHost)
    }

    public var sandboxKind: SandboxKind {
        normalizedHost == .thisMac ? .desktop : .browser
    }
}

// MARK: - Thread data (per-bot)

public struct ThreadData: Codable, Sendable {
    public var threadId: String
    public var cursor: Int
    public var messages: [ThreadMessage]
    public var run: Run?
    /// Full OpenAI-style transcript (tool calls + results) for the next agent turn.
    public var llmMessages: [ChatMessage]
    public var pendingTool: PendingAgentTool?

    public init(
        threadId: String,
        cursor: Int = -1,
        messages: [ThreadMessage] = [],
        run: Run? = nil,
        llmMessages: [ChatMessage] = [],
        pendingTool: PendingAgentTool? = nil
    ) {
        self.threadId = threadId
        self.cursor = cursor
        self.messages = messages
        self.run = run
        self.llmMessages = llmMessages
        self.pendingTool = pendingTool
    }

    public var nextSeq: Int { cursor + 1 }

    enum CodingKeys: String, CodingKey {
        case threadId, cursor, messages, run, llmMessages, pendingTool
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(String.self, forKey: .threadId)
        cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? -1
        messages = try c.decodeIfPresent([ThreadMessage].self, forKey: .messages) ?? []
        run = try c.decodeIfPresent(Run.self, forKey: .run)
        llmMessages = try c.decodeIfPresent([ChatMessage].self, forKey: .llmMessages) ?? []
        pendingTool = try c.decodeIfPresent(PendingAgentTool.self, forKey: .pendingTool)
    }
}

public struct PendingAgentTool: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String
    public var tool: String
    public var detail: String

    public init(name: String, arguments: String, tool: String, detail: String) {
        self.name = name
        self.arguments = arguments
        self.tool = tool
        self.detail = detail
    }
}

// MARK: - ID helper

public enum Ids {
    public static func new() -> String {
        UUID().uuidString.lowercased()
    }
}
