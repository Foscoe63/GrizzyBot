import Foundation

// MARK: - OpenMausBot-inspired product surfaces

public enum ComputerMode: String, Codable, Sendable, CaseIterable, Identifiable, CustomStringConvertible {
    case auto
    case cloud
    case localVM = "vm"
    case thisMac = "local"
    case off

    public var id: String { rawValue }
    public var description: String { label }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .cloud: return "Cloud desktop"
        case .localVM: return "Local VM"
        case .thisMac: return "This Mac"
        case .off: return "Off"
        }
    }
}

public enum ShellMainView: String, Codable, Sendable, Equatable {
    case chat
    case routines
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var profileName: String
    public var profileEmail: String
    /// Write-only secrets — UI only sees configured flags after save.
    public var composioConnectKey: String?
    public var composioApiKey: String?
    public var boxToken: String?
    public var ttsKey: String?
    /// Sentry DSN for crash reports. Empty keeps local last-crash.txt only.
    public var sentryDSN: String?
    public var ttsVoice: String?
    public var defaultComputerMode: ComputerMode
    /// Tool ids enabled for newly created bots.
    public var defaultEnabledTools: [String]
    public var launchAtLogin: Bool
    public var showMenuBar: Bool

    public init(
        profileName: String = "",
        profileEmail: String = "",
        composioConnectKey: String? = nil,
        composioApiKey: String? = nil,
        boxToken: String? = nil,
        ttsKey: String? = nil,
        sentryDSN: String? = nil,
        ttsVoice: String? = nil,
        defaultComputerMode: ComputerMode = .auto,
        defaultEnabledTools: [String] = AgentToolCatalog.allIds,
        launchAtLogin: Bool = false,
        showMenuBar: Bool = true
    ) {
        self.profileName = profileName
        self.profileEmail = profileEmail
        self.composioConnectKey = composioConnectKey
        self.composioApiKey = composioApiKey
        self.boxToken = boxToken
        self.ttsKey = ttsKey
        self.sentryDSN = sentryDSN
        self.ttsVoice = ttsVoice
        self.defaultComputerMode = defaultComputerMode
        self.defaultEnabledTools = defaultEnabledTools
        self.launchAtLogin = launchAtLogin
        self.showMenuBar = showMenuBar
    }

    enum CodingKeys: String, CodingKey {
        case profileName, profileEmail, composioConnectKey, composioApiKey, boxToken
        case ttsKey, sentryDSN, ttsVoice, defaultComputerMode, defaultEnabledTools, launchAtLogin, showMenuBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        profileEmail = try c.decodeIfPresent(String.self, forKey: .profileEmail) ?? ""
        composioConnectKey = try c.decodeIfPresent(String.self, forKey: .composioConnectKey)
        composioApiKey = try c.decodeIfPresent(String.self, forKey: .composioApiKey)
        boxToken = try c.decodeIfPresent(String.self, forKey: .boxToken)
        ttsKey = try c.decodeIfPresent(String.self, forKey: .ttsKey)
        sentryDSN = try c.decodeIfPresent(String.self, forKey: .sentryDSN)
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        defaultComputerMode = try c.decodeIfPresent(ComputerMode.self, forKey: .defaultComputerMode) ?? .auto
        defaultEnabledTools = try c.decodeIfPresent([String].self, forKey: .defaultEnabledTools)
            ?? AgentToolCatalog.allIds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileName, forKey: .profileName)
        try c.encode(profileEmail, forKey: .profileEmail)
        try c.encodeIfPresent(composioConnectKey, forKey: .composioConnectKey)
        try c.encodeIfPresent(composioApiKey, forKey: .composioApiKey)
        try c.encodeIfPresent(boxToken, forKey: .boxToken)
        try c.encodeIfPresent(ttsKey, forKey: .ttsKey)
        try c.encodeIfPresent(sentryDSN, forKey: .sentryDSN)
        try c.encodeIfPresent(ttsVoice, forKey: .ttsVoice)
        try c.encode(defaultComputerMode, forKey: .defaultComputerMode)
        try c.encode(defaultEnabledTools, forKey: .defaultEnabledTools)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showMenuBar, forKey: .showMenuBar)
    }

    public var composioConfigured: Bool {
        !(composioConnectKey ?? "").isEmpty || !(composioApiKey ?? "").isEmpty
    }

    public var boxConfigured: Bool { !(boxToken ?? "").isEmpty }
    public var ttsConfigured: Bool { !(ttsKey ?? "").isEmpty }
    public var sentryConfigured: Bool { !(sentryDSN ?? "").isEmpty }

    /// Local Settings copy so agents answer key questions without searching the web.
    public static let keysHelp = """
    This Mac → Settings → Connections → Keys:
    - Composio Connect: the OAuth key that turns Plugins into real browser sign-in (Gmail, Slack, GitHub, Box, …). Get it from app.composio.dev.
    - Composio API: optional backend API key for Composio REST.
    - Box.com: optional Box developer token for the Box plugin when you are not using Composio Connect. It is not the Composio Connect key.
    Questions about these labels are local Settings fields — do not search the web for them.
    Speak replies uses ElevenLabs when a TTS key is saved, otherwise a macOS voice.
    Diagnostics → Sentry DSN sends crashes to your Sentry project; last-crash.txt is always local.
    """
}

public struct BotTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var threadId: String
    public var createdAt: Date

    public init(id: String = Ids.new(), title: String, threadId: String = Ids.new(), createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.threadId = threadId
        self.createdAt = createdAt
    }
}

public enum GroupResponder: Codable, Sendable, Hashable {
    case everyone
    case mentions
    case member(botId: String)
}

public struct GroupRoom: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var memberIds: [String]
    public var bulletin: String
    public var defaultResponder: GroupResponder
    public var unread: Bool
    public var threadId: String
    public var preview: String
    public var createdAt: Date

    public init(
        id: String = Ids.new(),
        name: String,
        memberIds: [String],
        bulletin: String = "",
        defaultResponder: GroupResponder = .everyone,
        unread: Bool = false,
        threadId: String = Ids.new(),
        preview: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.memberIds = memberIds
        self.bulletin = bulletin
        self.defaultResponder = defaultResponder
        self.unread = unread
        self.threadId = threadId
        self.preview = preview
        self.createdAt = createdAt
    }
}

public struct MessageReaction: Codable, Sendable, Hashable, Identifiable {
    public var id: String { emoji }
    public var emoji: String
    public var count: Int

    public init(emoji: String, count: Int = 1) {
        self.emoji = emoji
        self.count = count
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allow
    case deny
    case alwaysAllow = "always_allow"
}
