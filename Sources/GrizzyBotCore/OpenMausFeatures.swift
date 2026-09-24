import Foundation

// MARK: - OpenMausBot-inspired product surfaces

public enum ComputerMode: String, Sendable, CaseIterable, Identifiable, CustomStringConvertible {
    case auto
    case inAppBrowser = "in-app-browser"
    case thisMac = "local"
    case off

    public var id: String { rawValue }
    public var description: String { label }

    /// Modes shown in Settings and bot panels.
    public static var selectableCases: [ComputerMode] {
        [.auto, .inAppBrowser, .thisMac, .off]
    }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .inAppBrowser: return "In-app browser"
        case .thisMac: return "This Mac"
        case .off: return "Off"
        }
    }

    public static func parse(_ raw: String) -> ComputerMode {
        switch raw {
        case "auto": return .auto
        case "in-app-browser", "cloud", "browser", "docker": return .inAppBrowser
        case "vm", "localVM": return .inAppBrowser
        case "local", "this-mac", "thisMac": return .thisMac
        case "off": return .off
        default: return .auto
        }
    }
}

extension ComputerMode: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ComputerMode.parse(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ShellMainView: String, Codable, Sendable, Equatable {
    case chat
    case routines
    case botChat
}

public enum ThemeAppearanceMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var profileName: String
    public var profileEmail: String
    /// Write-only secrets — UI only sees configured flags after save.
    public var composioConnectKey: String?
    public var composioApiKey: String?
    public var googleClientId: String?
    public var googleClientSecret: String?
    public var boxToken: String?
    public var ttsKey: String?
    /// Sentry DSN for crash reports. Empty keeps local last-crash.txt only.
    public var sentryDSN: String?
    public var braveSearchKey: String?
    public var ttsVoice: String?
    public var defaultComputerMode: ComputerMode
    /// Tool ids enabled for newly created bots.
    public var defaultEnabledTools: [String]
    /// Tool ids already offered for default opt-in. Absent from `defaultEnabledTools` means off — do not revive.
    public var seenToolIds: [String]
    public var launchAtLogin: Bool
    public var showMenuBar: Bool
    /// Hide the main window at launch; GrizzyBot stays in the menu bar until opened.
    public var menuBarOnly: Bool
    /// Register the LaunchAgent helper so due routines wake the app in the background.
    public var backgroundRoutines: Bool
    /// System / light / dark appearance for built-in themes.
    public var themeAppearanceMode: ThemeAppearanceMode
    /// Active built-in theme preset id (Osaurus-compatible gallery).
    public var activeThemePresetId: String?
    /// Silence limit for model streams. 0 disables. Default 60s.
    public var agentStallTimeoutMs: Int
    /// Scrub / block PII before cloud model sends.
    public var privacyFilter: PrivacyFilterSettings
    /// Lean memory injection gate.
    public var memoryRelevanceMode: MemoryRelevanceGateMode
    /// Local OpenAI-compatible gateway for Cursor / external clients.
    public var localGateway: LocalOpenAIGateway.Settings
    public var enableFolderWatchers: Bool

    public init(
        profileName: String = "",
        profileEmail: String = "",
        composioConnectKey: String? = nil,
        composioApiKey: String? = nil,
        googleClientId: String? = nil,
        googleClientSecret: String? = nil,
        boxToken: String? = nil,
        ttsKey: String? = nil,
        sentryDSN: String? = nil,
        braveSearchKey: String? = nil,
        ttsVoice: String? = nil,
        defaultComputerMode: ComputerMode = .auto,
        defaultEnabledTools: [String] = AgentToolCatalog.allIds,
        seenToolIds: [String] = [],
        launchAtLogin: Bool = false,
        showMenuBar: Bool = true,
        menuBarOnly: Bool = false,
        backgroundRoutines: Bool = false,
        themeAppearanceMode: ThemeAppearanceMode = .dark,
        activeThemePresetId: String? = "grizzy-default",
        agentStallTimeoutMs: Int = 60_000,
        privacyFilter: PrivacyFilterSettings = .default,
        memoryRelevanceMode: MemoryRelevanceGateMode = .heuristic,
        localGateway: LocalOpenAIGateway.Settings = .default,
        enableFolderWatchers: Bool = true
    ) {
        self.profileName = profileName
        self.profileEmail = profileEmail
        self.composioConnectKey = composioConnectKey
        self.composioApiKey = composioApiKey
        self.googleClientId = googleClientId
        self.googleClientSecret = googleClientSecret
        self.boxToken = boxToken
        self.ttsKey = ttsKey
        self.sentryDSN = sentryDSN
        self.braveSearchKey = braveSearchKey
        self.ttsVoice = ttsVoice
        self.defaultComputerMode = defaultComputerMode
        self.defaultEnabledTools = defaultEnabledTools
        self.seenToolIds = seenToolIds
        self.launchAtLogin = launchAtLogin
        self.showMenuBar = showMenuBar
        self.menuBarOnly = menuBarOnly
        self.backgroundRoutines = backgroundRoutines
        self.themeAppearanceMode = themeAppearanceMode
        self.activeThemePresetId = activeThemePresetId
        self.agentStallTimeoutMs = agentStallTimeoutMs
        self.privacyFilter = privacyFilter
        self.memoryRelevanceMode = memoryRelevanceMode
        self.localGateway = localGateway
        self.enableFolderWatchers = enableFolderWatchers
    }

    enum CodingKeys: String, CodingKey {
        case profileName, profileEmail, composioConnectKey, composioApiKey
        case googleClientId, googleClientSecret, boxToken
        case ttsKey, sentryDSN, braveSearchKey, ttsVoice, defaultComputerMode, defaultEnabledTools, seenToolIds, launchAtLogin, showMenuBar, menuBarOnly, backgroundRoutines
        case themeAppearanceMode, activeThemePresetId, agentStallTimeoutMs
        case privacyFilter, memoryRelevanceMode, localGateway, enableFolderWatchers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        profileEmail = try c.decodeIfPresent(String.self, forKey: .profileEmail) ?? ""
        composioConnectKey = try c.decodeIfPresent(String.self, forKey: .composioConnectKey)
        composioApiKey = try c.decodeIfPresent(String.self, forKey: .composioApiKey)
        googleClientId = try c.decodeIfPresent(String.self, forKey: .googleClientId)
        googleClientSecret = try c.decodeIfPresent(String.self, forKey: .googleClientSecret)
        boxToken = try c.decodeIfPresent(String.self, forKey: .boxToken)
        ttsKey = try c.decodeIfPresent(String.self, forKey: .ttsKey)
        sentryDSN = try c.decodeIfPresent(String.self, forKey: .sentryDSN)
        braveSearchKey = try c.decodeIfPresent(String.self, forKey: .braveSearchKey)
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        defaultComputerMode = try c.decodeIfPresent(ComputerMode.self, forKey: .defaultComputerMode) ?? .auto
        defaultEnabledTools = try c.decodeIfPresent([String].self, forKey: .defaultEnabledTools)
            ?? AgentToolCatalog.allIds
        seenToolIds = try c.decodeIfPresent([String].self, forKey: .seenToolIds) ?? []
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        menuBarOnly = try c.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? false
        backgroundRoutines = try c.decodeIfPresent(Bool.self, forKey: .backgroundRoutines) ?? false
        themeAppearanceMode = try c.decodeIfPresent(ThemeAppearanceMode.self, forKey: .themeAppearanceMode) ?? .dark
        activeThemePresetId = try c.decodeIfPresent(String.self, forKey: .activeThemePresetId) ?? "grizzy-default"
        agentStallTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .agentStallTimeoutMs) ?? 60_000
        privacyFilter = try c.decodeIfPresent(PrivacyFilterSettings.self, forKey: .privacyFilter) ?? .default
        memoryRelevanceMode = try c.decodeIfPresent(MemoryRelevanceGateMode.self, forKey: .memoryRelevanceMode) ?? .heuristic
        localGateway = try c.decodeIfPresent(LocalOpenAIGateway.Settings.self, forKey: .localGateway) ?? .default
        enableFolderWatchers = try c.decodeIfPresent(Bool.self, forKey: .enableFolderWatchers) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileName, forKey: .profileName)
        try c.encode(profileEmail, forKey: .profileEmail)
        try c.encodeIfPresent(composioConnectKey, forKey: .composioConnectKey)
        try c.encodeIfPresent(composioApiKey, forKey: .composioApiKey)
        try c.encodeIfPresent(googleClientId, forKey: .googleClientId)
        try c.encodeIfPresent(googleClientSecret, forKey: .googleClientSecret)
        try c.encodeIfPresent(boxToken, forKey: .boxToken)
        try c.encodeIfPresent(ttsKey, forKey: .ttsKey)
        try c.encodeIfPresent(sentryDSN, forKey: .sentryDSN)
        try c.encodeIfPresent(braveSearchKey, forKey: .braveSearchKey)
        try c.encodeIfPresent(ttsVoice, forKey: .ttsVoice)
        try c.encode(defaultComputerMode, forKey: .defaultComputerMode)
        try c.encode(defaultEnabledTools, forKey: .defaultEnabledTools)
        try c.encode(seenToolIds, forKey: .seenToolIds)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showMenuBar, forKey: .showMenuBar)
        try c.encode(menuBarOnly, forKey: .menuBarOnly)
        try c.encode(backgroundRoutines, forKey: .backgroundRoutines)
        try c.encode(themeAppearanceMode, forKey: .themeAppearanceMode)
        try c.encodeIfPresent(activeThemePresetId, forKey: .activeThemePresetId)
        try c.encode(agentStallTimeoutMs, forKey: .agentStallTimeoutMs)
        try c.encode(privacyFilter, forKey: .privacyFilter)
        try c.encode(memoryRelevanceMode, forKey: .memoryRelevanceMode)
        try c.encode(localGateway, forKey: .localGateway)
        try c.encode(enableFolderWatchers, forKey: .enableFolderWatchers)
    }

    public var composioConfigured: Bool {
        !(composioConnectKey ?? "").isEmpty || !(composioApiKey ?? "").isEmpty
    }

    public var googleOAuthConfigured: Bool {
        !(googleClientId ?? "").isEmpty && !(googleClientSecret ?? "").isEmpty
    }

    public var boxConfigured: Bool { !(boxToken ?? "").isEmpty }
    public var ttsConfigured: Bool { !(ttsKey ?? "").isEmpty }
    public var sentryConfigured: Bool { !(sentryDSN ?? "").isEmpty }
    public var braveSearchConfigured: Bool { !(braveSearchKey ?? "").isEmpty }

    /// Local Settings copy so agents answer key questions without searching the web.
    public static let keysHelp = """
    This Mac → Settings → Connections → Keys:
    - Composio Connect: the OAuth key that turns Plugins into real browser sign-in (Gmail, Slack, GitHub, Box, …). Get it from app.composio.dev.
    - Composio API: optional backend API key for Composio REST.
    - Google Client ID / Client Secret: optional Desktop OAuth credentials from Google Cloud Console. Lets Gmail, Calendar, Sheets, Docs, and Drive bypass Composio. Use the in-app setup guide under Connections → Google.
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
