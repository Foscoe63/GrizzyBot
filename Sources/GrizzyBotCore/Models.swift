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
        createdAt: Date = .now
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

    public init(
        id: String,
        threadId: String,
        seq: Int,
        role: MessageRole,
        blocks: [MessageBlock],
        runId: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.threadId = threadId
        self.seq = seq
        self.role = role
        self.blocks = blocks
        self.runId = runId
        self.createdAt = createdAt
    }

    /// First plain-text content, used for the sidebar preview.
    public var firstText: String {
        for block in blocks {
            if case .text(let t) = block, !t.isEmpty { return t }
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
        completedAt: Date? = nil
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
    }
}

// MARK: - Computer (rakazo `ComputerStatusSchema` / `SandboxKind`)

public enum SandboxKind: String, Codable, Sendable {
    case docker
    case e2b
    case desktop
    case fake
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

    public init(
        botId: String,
        kind: SandboxKind = .docker,
        state: ComputerState = .stopped,
        controlHolder: ControlHolder = .none,
        screenAvailable: Bool = false
    ) {
        self.botId = botId
        self.kind = kind
        self.state = state
        self.controlHolder = controlHolder
        self.screenAvailable = screenAvailable
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
        createdAt: Date = .now
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
    }
}

// MARK: - Plugins / connections (rakazo `ConnectionCatalogItemSchema`)

public struct ConnectionItem: Codable, Sendable, Hashable, Identifiable {
    public var slug: String
    public var name: String
    public var logo: String?
    public var connected: Bool
    public var noAuth: Bool

    public var id: String { slug }

    public init(slug: String, name: String, logo: String? = nil, connected: Bool = false, noAuth: Bool = false) {
        self.slug = slug
        self.name = name
        self.logo = logo
        self.connected = connected
        self.noAuth = noAuth
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
    }

    public struct MemoryEntry: Codable, Sendable {
        public var path: String
        public var content: String
    }

    public struct RoutineExport: Codable, Sendable {
        public var name: String
        public var prompt: String
        public var cron: String
        public var timezone: String
    }

    public struct FileEntry: Codable, Sendable {
        public var path: String
        public var content: String
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

// MARK: - User / session (rakazo `MeSchema`)

public struct UserAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var email: String
    public var name: String
    /// SHA-256 hex digest of the password. Never stored in plaintext.
    public var passwordHash: String
    public var createdAt: Date

    public init(id: String, email: String, name: String, passwordHash: String, createdAt: Date = .now) {
        self.id = id
        self.email = email
        self.name = name
        self.passwordHash = passwordHash
        self.createdAt = createdAt
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
    public var computerHost: String? // "docker" | "this-mac" | nil
    public var canChooseHostComputer: Bool

    public init(computerHost: String? = nil, canChooseHostComputer: Bool = true) {
        self.computerHost = computerHost
        self.canChooseHostComputer = canChooseHostComputer
    }

    public var sandboxKind: SandboxKind {
        computerHost == "this-mac" ? .desktop : .docker
    }
}

// MARK: - Thread data (per-bot)

public struct ThreadData: Codable, Sendable {
    public var threadId: String
    public var cursor: Int
    public var messages: [ThreadMessage]
    public var run: Run?

    public init(threadId: String, cursor: Int = -1, messages: [ThreadMessage] = [], run: Run? = nil) {
        self.threadId = threadId
        self.cursor = cursor
        self.messages = messages
        self.run = run
    }

    public var nextSeq: Int { cursor + 1 }
}

// MARK: - ID helper

public enum Ids {
    public static func new() -> String {
        UUID().uuidString.lowercased()
    }
}
