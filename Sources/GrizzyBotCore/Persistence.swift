import CryptoKit
import Foundation

/// Per-user workspace persisted as `user-{userId}.json`.
public struct UserWorkspace: Codable, Sendable {
    public var bots: [Bot]
    public var threads: [String: ThreadData]
    public var routines: [String: [Routine]]
    public var computers: [String: ComputerStatus]
    public var connections: [ConnectionItem]
    public var usage: [UsageRecord]
    public var memory: [MemoryDocument]
    /// Bot-home files written by the scripted runtime: `[path, content]`.
    public var files: [[String]]
    public var deployment: DeploymentSettings
    public var modelProvider: String?
    public var modelId: String?
    public var apiKey: String?
    public var modelBaseUrl: String?
    public var fetchedModels: [LocalModelRef]
    public var groups: [GroupRoom]
    public var appConfig: AppConfig
    public var customTools: [CustomAgentTool]
    public var mcpServers: [McpServer]
    public var oauthJSON: String?
    public var connectionSecrets: [String: String]

    public init(
        bots: [Bot] = [],
        threads: [String: ThreadData] = [:],
        routines: [String: [Routine]] = [:],
        computers: [String: ComputerStatus] = [:],
        connections: [ConnectionItem] = ConnectionCatalog.defaults,
        usage: [UsageRecord] = [],
        memory: [MemoryDocument] = [],
        files: [[String]] = [],
        deployment: DeploymentSettings = DeploymentSettings(),
        modelProvider: String? = nil,
        modelId: String? = nil,
        apiKey: String? = nil,
        modelBaseUrl: String? = nil,
        fetchedModels: [LocalModelRef] = [],
        groups: [GroupRoom] = [],
        appConfig: AppConfig = AppConfig(),
        customTools: [CustomAgentTool] = [],
        mcpServers: [McpServer] = [],
        oauthJSON: String? = nil,
        connectionSecrets: [String: String] = [:]
    ) {
        self.bots = bots
        self.threads = threads
        self.routines = routines
        self.computers = computers
        self.connections = connections
        self.usage = usage
        self.memory = memory
        self.files = files
        self.deployment = deployment
        self.modelProvider = modelProvider
        self.modelId = modelId
        self.apiKey = apiKey
        self.modelBaseUrl = modelBaseUrl
        self.fetchedModels = fetchedModels
        self.groups = groups
        self.appConfig = appConfig
        self.customTools = customTools
        self.mcpServers = mcpServers
        self.oauthJSON = oauthJSON
        self.connectionSecrets = connectionSecrets
    }

    enum CodingKeys: String, CodingKey {
        case bots, threads, routines, computers, connections, usage, memory, files
        case deployment, modelProvider, modelId, apiKey, modelBaseUrl, fetchedModels
        case groups, appConfig, customTools, mcpServers, oauthJSON, connectionSecrets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bots = try c.decodeIfPresent([Bot].self, forKey: .bots) ?? []
        threads = try c.decodeIfPresent([String: ThreadData].self, forKey: .threads) ?? [:]
        routines = try c.decodeIfPresent([String: [Routine]].self, forKey: .routines) ?? [:]
        computers = try c.decodeIfPresent([String: ComputerStatus].self, forKey: .computers) ?? [:]
        connections = try c.decodeIfPresent([ConnectionItem].self, forKey: .connections) ?? ConnectionCatalog.defaults
        usage = try c.decodeIfPresent([UsageRecord].self, forKey: .usage) ?? []
        memory = try c.decodeIfPresent([MemoryDocument].self, forKey: .memory) ?? []
        files = try c.decodeIfPresent([[String]].self, forKey: .files) ?? []
        deployment = try c.decodeIfPresent(DeploymentSettings.self, forKey: .deployment) ?? DeploymentSettings()
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        modelBaseUrl = try c.decodeIfPresent(String.self, forKey: .modelBaseUrl)
        fetchedModels = try c.decodeIfPresent([LocalModelRef].self, forKey: .fetchedModels) ?? []
        groups = try c.decodeIfPresent([GroupRoom].self, forKey: .groups) ?? []
        appConfig = try c.decodeIfPresent(AppConfig.self, forKey: .appConfig) ?? AppConfig()
        customTools = try c.decodeIfPresent([CustomAgentTool].self, forKey: .customTools) ?? []
        mcpServers = try c.decodeIfPresent([McpServer].self, forKey: .mcpServers) ?? []
        oauthJSON = try c.decodeIfPresent(String.self, forKey: .oauthJSON)
        connectionSecrets = try c.decodeIfPresent([String: String].self, forKey: .connectionSecrets) ?? [:]
    }
}

/// Built-in plugin catalog. Connect uses Composio OAuth when a Connect key is set.
public enum ConnectionCatalog {
    public static let defaults: [ConnectionItem] = [
        ConnectionItem(slug: "gmail", name: "Gmail", blurb: "Read and send email", domain: "gmail.com"),
        ConnectionItem(slug: "slack", name: "Slack", blurb: "Post updates and read channels", domain: "slack.com"),
        ConnectionItem(slug: "github", name: "GitHub", blurb: "Issues, pull requests, and code", domain: "github.com"),
        ConnectionItem(slug: "notion", name: "Notion", blurb: "Pages and databases", domain: "notion.so"),
        ConnectionItem(slug: "linear", name: "Linear", blurb: "Issues and project tracking", domain: "linear.app"),
        ConnectionItem(slug: "google-calendar", name: "Google Calendar", blurb: "Read and create events", domain: "calendar.google.com"),
        ConnectionItem(slug: "google-sheets", name: "Google Sheets", blurb: "Read and update spreadsheets", domain: "sheets.google.com"),
        ConnectionItem(slug: "google-docs", name: "Google Docs", blurb: "Read and write documents", domain: "docs.google.com"),
        ConnectionItem(slug: "google-drive", name: "Google Drive", blurb: "Browse and manage files", domain: "drive.google.com"),
        ConnectionItem(slug: "hubspot", name: "HubSpot", blurb: "CRM search and updates", domain: "hubspot.com"),
        ConnectionItem(slug: "salesforce", name: "Salesforce", blurb: "CRM records and reports", domain: "salesforce.com"),
        ConnectionItem(slug: "jira", name: "Jira", blurb: "Issues and sprints", domain: "atlassian.com"),
        ConnectionItem(slug: "trello", name: "Trello", blurb: "Boards and cards", domain: "trello.com"),
        ConnectionItem(slug: "asana", name: "Asana", blurb: "Tasks and projects", domain: "asana.com"),
        ConnectionItem(slug: "intercom", name: "Intercom", blurb: "Inbox and conversations", domain: "intercom.com"),
        ConnectionItem(slug: "discord", name: "Discord", blurb: "Messages and channels", domain: "discord.com"),
        ConnectionItem(slug: "x", name: "X (Twitter)", blurb: "Post and read on X", domain: "x.com"),
        ConnectionItem(slug: "stripe", name: "Stripe", blurb: "Payments and customers", domain: "stripe.com"),
        ConnectionItem(slug: "dropbox", name: "Dropbox", blurb: "Files and folders", domain: "dropbox.com"),
        ConnectionItem(
            slug: "box",
            name: "Box",
            tokenHint: "Box developer token",
            blurb: "Files and folders on Box.com",
            domain: "box.com"
        ),
        ConnectionItem(slug: "figma", name: "Figma", blurb: "Files and comments", domain: "figma.com"),
        ConnectionItem(slug: "airtable", name: "Airtable", blurb: "Bases and records", domain: "airtable.com"),
    ]
}

/// JSON file persistence under Application Support (or a test override path).
public struct Persistence: Sendable {
    public let root: URL

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = appSupport.appendingPathComponent("GrizzyBot", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: - Password hashing

    public static func hashPassword(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Users / session

    public func loadUsers() -> [UserAccount] {
        load([UserAccount].self, from: "users.json") ?? []
    }

    public func saveUsers(_ users: [UserAccount]) {
        save(users, to: "users.json")
    }

    public func loadSession() -> Session? {
        load(Session.self, from: "session.json")
    }

    public func saveSession(_ session: Session?) {
        if let session {
            save(session, to: "session.json")
        } else {
            let url = root.appendingPathComponent("session.json")
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Workspace

    public func loadWorkspace(userId: String) -> UserWorkspace {
        load(UserWorkspace.self, from: "user-\(userId).json") ?? UserWorkspace()
    }

    public func saveWorkspace(_ workspace: UserWorkspace, userId: String) {
        save(workspace, to: "user-\(userId).json")
    }

    public func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        try Self.encoder.encode(value)
    }

    public func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try Self.decoder.decode(type, from: data)
    }

    public var diagnosticsDirectory: URL {
        let dir = root.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Workspace snapshots

    public func snapshotDirectory(userId: String) -> URL {
        let dir = root.appendingPathComponent("snapshots/\(userId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func saveSnapshot(_ snapshot: WorkspaceSnapshot, userId: String) {
        let url = snapshotDirectory(userId: userId).appendingPathComponent("\(snapshot.meta.id).json")
        save(snapshot, toURL: url)
    }

    public func loadSnapshot(id: String, userId: String) -> WorkspaceSnapshot? {
        let url = snapshotDirectory(userId: userId).appendingPathComponent("\(id).json")
        return load(WorkspaceSnapshot.self, fromURL: url)
    }

    public func listSnapshots(userId: String) -> [WorkspaceSnapshotMeta] {
        let dir = snapshotDirectory(userId: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> WorkspaceSnapshotMeta? in
                load(WorkspaceSnapshot.self, fromURL: dir.appendingPathComponent(name))?.meta
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func deleteSnapshot(id: String, userId: String) {
        let url = snapshotDirectory(userId: userId).appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        load(type, fromURL: root.appendingPathComponent(name))
    }

    private func load<T: Decodable>(_ type: T.Type, fromURL url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        save(value, toURL: root.appendingPathComponent(name))
    }

    private func save<T: Encodable>(_ value: T, toURL url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }
}
