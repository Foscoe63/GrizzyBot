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
    public var ttsVoice: String?
    public var defaultComputerMode: ComputerMode
    /// Tool ids enabled for newly created bots.
    public var defaultEnabledTools: [String]

    public init(
        profileName: String = "",
        profileEmail: String = "",
        composioConnectKey: String? = nil,
        composioApiKey: String? = nil,
        boxToken: String? = nil,
        ttsKey: String? = nil,
        ttsVoice: String? = nil,
        defaultComputerMode: ComputerMode = .auto,
        defaultEnabledTools: [String] = AgentToolCatalog.allIds
    ) {
        self.profileName = profileName
        self.profileEmail = profileEmail
        self.composioConnectKey = composioConnectKey
        self.composioApiKey = composioApiKey
        self.boxToken = boxToken
        self.ttsKey = ttsKey
        self.ttsVoice = ttsVoice
        self.defaultComputerMode = defaultComputerMode
        self.defaultEnabledTools = defaultEnabledTools
    }

    enum CodingKeys: String, CodingKey {
        case profileName, profileEmail, composioConnectKey, composioApiKey, boxToken
        case ttsKey, ttsVoice, defaultComputerMode, defaultEnabledTools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        profileEmail = try c.decodeIfPresent(String.self, forKey: .profileEmail) ?? ""
        composioConnectKey = try c.decodeIfPresent(String.self, forKey: .composioConnectKey)
        composioApiKey = try c.decodeIfPresent(String.self, forKey: .composioApiKey)
        boxToken = try c.decodeIfPresent(String.self, forKey: .boxToken)
        ttsKey = try c.decodeIfPresent(String.self, forKey: .ttsKey)
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        defaultComputerMode = try c.decodeIfPresent(ComputerMode.self, forKey: .defaultComputerMode) ?? .auto
        defaultEnabledTools = try c.decodeIfPresent([String].self, forKey: .defaultEnabledTools)
            ?? AgentToolCatalog.allIds
    }

    public var composioConfigured: Bool {
        !(composioConnectKey ?? "").isEmpty || !(composioApiKey ?? "").isEmpty
    }

    public var boxConfigured: Bool { !(boxToken ?? "").isEmpty }
    public var ttsConfigured: Bool { !(ttsKey ?? "").isEmpty }
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
