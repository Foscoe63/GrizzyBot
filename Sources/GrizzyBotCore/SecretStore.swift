import Foundation
import Security

/// Workspace secrets live in the Keychain — never in JSON on disk or in exports.
public struct WorkspaceSecrets: Codable, Sendable, Equatable {
    public var apiKey: String?
    public var oauthJSON: String?
    public var providerCredentials: [String: ProviderCredential]
    public var connectionSecrets: [String: String]
    public var composioConnectKey: String?
    public var composioApiKey: String?
    public var boxToken: String?
    public var ttsKey: String?
    public var sentryDSN: String?
    public var braveSearchKey: String?

    public init(
        apiKey: String? = nil,
        oauthJSON: String? = nil,
        providerCredentials: [String: ProviderCredential] = [:],
        connectionSecrets: [String: String] = [:],
        composioConnectKey: String? = nil,
        composioApiKey: String? = nil,
        boxToken: String? = nil,
        ttsKey: String? = nil,
        sentryDSN: String? = nil,
        braveSearchKey: String? = nil
    ) {
        self.apiKey = apiKey
        self.oauthJSON = oauthJSON
        self.providerCredentials = providerCredentials
        self.connectionSecrets = connectionSecrets
        self.composioConnectKey = composioConnectKey
        self.composioApiKey = composioApiKey
        self.boxToken = boxToken
        self.ttsKey = ttsKey
        self.sentryDSN = sentryDSN
        self.braveSearchKey = braveSearchKey
    }

    public static func from(workspace: UserWorkspace) -> WorkspaceSecrets {
        WorkspaceSecrets(
            apiKey: workspace.apiKey,
            oauthJSON: workspace.oauthJSON,
            providerCredentials: [:],
            connectionSecrets: workspace.connectionSecrets,
            composioConnectKey: workspace.appConfig.composioConnectKey,
            composioApiKey: workspace.appConfig.composioApiKey,
            boxToken: workspace.appConfig.boxToken,
            ttsKey: workspace.appConfig.ttsKey,
            sentryDSN: workspace.appConfig.sentryDSN,
            braveSearchKey: workspace.appConfig.braveSearchKey
        )
    }

    public func applying(to workspace: UserWorkspace) -> UserWorkspace {
        var next = workspace
        next.apiKey = apiKey
        next.oauthJSON = oauthJSON
        next.connectionSecrets = connectionSecrets
        next.appConfig.composioConnectKey = composioConnectKey
        next.appConfig.composioApiKey = composioApiKey
        next.appConfig.boxToken = boxToken
        next.appConfig.ttsKey = ttsKey
        next.appConfig.sentryDSN = sentryDSN
        next.appConfig.braveSearchKey = braveSearchKey
        return next
    }

    public func stripped(from workspace: UserWorkspace) -> UserWorkspace {
        var next = workspace
        next.apiKey = nil
        next.oauthJSON = nil
        next.connectionSecrets = [:]
        next.appConfig.composioConnectKey = nil
        next.appConfig.composioApiKey = nil
        next.appConfig.boxToken = nil
        next.appConfig.ttsKey = nil
        next.appConfig.sentryDSN = nil
        next.appConfig.braveSearchKey = nil
        return next
    }

    public var isEmpty: Bool {
        (apiKey ?? "").isEmpty
            && (oauthJSON ?? "").isEmpty
            && providerCredentials.values.allSatisfy(\.isEmpty)
            && connectionSecrets.isEmpty
            && (composioConnectKey ?? "").isEmpty
            && (composioApiKey ?? "").isEmpty
            && (boxToken ?? "").isEmpty
            && (ttsKey ?? "").isEmpty
            && (sentryDSN ?? "").isEmpty
            && (braveSearchKey ?? "").isEmpty
    }
}

public enum SecretStore {
    private static let service = "com.grizzybot.app.secrets"

    public static func load(userId: String) -> WorkspaceSecrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WorkspaceSecrets.self, from: data)
    }

    public static func save(_ secrets: WorkspaceSecrets, userId: String) throws {
        let data = try JSONEncoder().encode(secrets)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychain(addStatus)
            }
            return
        }
        throw SecretStoreError.keychain(status)
    }

    public static func delete(userId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(userId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Move inline secrets from a loaded workspace into Keychain and return a stripped workspace for disk.
    public static func migrateInlineSecretsIfNeeded(_ workspace: UserWorkspace, userId: String) -> UserWorkspace {
        let inline = WorkspaceSecrets.from(workspace: workspace)
        guard !inline.isEmpty else { return workspace }
        if var existing = load(userId: userId) {
            if inline.apiKey != nil { existing.apiKey = inline.apiKey }
            if inline.oauthJSON != nil { existing.oauthJSON = inline.oauthJSON }
            if !inline.providerCredentials.isEmpty {
                existing.providerCredentials.merge(inline.providerCredentials) { _, new in new }
            }
            if !inline.connectionSecrets.isEmpty {
                existing.connectionSecrets.merge(inline.connectionSecrets) { _, new in new }
            }
            if inline.composioConnectKey != nil { existing.composioConnectKey = inline.composioConnectKey }
            if inline.composioApiKey != nil { existing.composioApiKey = inline.composioApiKey }
            if inline.boxToken != nil { existing.boxToken = inline.boxToken }
            if inline.ttsKey != nil { existing.ttsKey = inline.ttsKey }
            if inline.sentryDSN != nil { existing.sentryDSN = inline.sentryDSN }
            if inline.braveSearchKey != nil { existing.braveSearchKey = inline.braveSearchKey }
            try? save(existing, userId: userId)
        } else {
            try? save(inline, userId: userId)
        }
        return inline.stripped(from: workspace)
    }

    private static func account(_ userId: String) -> String { "workspace-\(userId)" }
}

public enum SecretStoreError: Error, Sendable {
    case keychain(OSStatus)
}

public enum ComputerHost: String, Sendable, Codable, CaseIterable {
    case inAppBrowser = "in-app-browser"
    case thisMac = "this-mac"

    public var label: String {
        switch self {
        case .inAppBrowser: return "In-app browser"
        case .thisMac: return "This Mac"
        }
    }

    public static func normalize(_ raw: String?) -> ComputerHost? {
        guard let raw else { return nil }
        switch raw {
        case Self.inAppBrowser.rawValue, "docker", "browser", "cloud": return .inAppBrowser
        case Self.thisMac.rawValue: return .thisMac
        default: return nil
        }
    }
}
