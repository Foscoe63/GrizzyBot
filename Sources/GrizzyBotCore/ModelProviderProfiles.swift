import Foundation

/// Non-secret settings saved per model provider (base URL, model id, fetched list).
public struct ModelProviderProfile: Codable, Sendable, Equatable {
    public var modelId: String?
    public var baseUrl: String?
    public var fetchedModels: [LocalModelRef]
    public var enabled: Bool

    public init(
        modelId: String? = nil,
        baseUrl: String? = nil,
        fetchedModels: [LocalModelRef] = [],
        enabled: Bool = false
    ) {
        self.modelId = modelId
        self.baseUrl = baseUrl
        self.fetchedModels = fetchedModels
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case modelId, baseUrl, fetchedModels, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        fetchedModels = try c.decodeIfPresent([LocalModelRef].self, forKey: .fetchedModels) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// API key / OAuth token for one provider — stored in Keychain only.
public struct ProviderCredential: Codable, Sendable, Equatable {
    public var apiKey: String?
    public var oauthJSON: String?

    public init(apiKey: String? = nil, oauthJSON: String? = nil) {
        self.apiKey = apiKey
        self.oauthJSON = oauthJSON
    }

    public var isEmpty: Bool {
        (apiKey ?? "").isEmpty && (oauthJSON ?? "").isEmpty
    }
}

/// Resolved settings for UI or LLM routing.
public struct ModelProviderSettings: Sendable, Equatable {
    public var modelId: String?
    public var apiKey: String?
    public var baseUrl: String?
    public var oauthJSON: String?
    public var fetchedModels: [LocalModelRef]
    public var enabled: Bool

    public init(
        modelId: String? = nil,
        apiKey: String? = nil,
        baseUrl: String? = nil,
        oauthJSON: String? = nil,
        fetchedModels: [LocalModelRef] = [],
        enabled: Bool = false
    ) {
        self.modelId = modelId
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.oauthJSON = oauthJSON
        self.fetchedModels = fetchedModels
        self.enabled = enabled
    }
}

public enum ModelProviderProfiles {
    /// Upgrade single-provider workspace fields into per-provider maps.
    public static func migrateProfiles(from workspace: UserWorkspace) -> [String: ModelProviderProfile] {
        if !workspace.providerProfiles.isEmpty { return workspace.providerProfiles }
        guard let provider = workspace.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty else { return [:] }
        return [
            provider: ModelProviderProfile(
                modelId: workspace.modelId,
                baseUrl: workspace.modelBaseUrl,
                fetchedModels: workspace.fetchedModels,
                enabled: true
            ),
        ]
    }

    public static func migrateCredentials(
        from workspace: UserWorkspace,
        existing: [String: ProviderCredential]
    ) -> [String: ProviderCredential] {
        if !existing.isEmpty { return existing }
        guard let provider = workspace.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty else { return [:] }
        let cred = ProviderCredential(apiKey: workspace.apiKey, oauthJSON: workspace.oauthJSON)
        guard !cred.isEmpty else { return [:] }
        return [provider: cred]
    }

    public static func settings(
        provider: String,
        profiles: [String: ModelProviderProfile],
        credentials: [String: ProviderCredential],
        activeProvider: String?,
        activeModelId: String?,
        activeBaseUrl: String?,
        activeFetched: [LocalModelRef],
        activeApiKey: String?,
        activeOAuthJSON: String?
    ) -> ModelProviderSettings {
        let profile = profiles[provider]
        let cred = credentials[provider]
        let isActive = provider == activeProvider
        return ModelProviderSettings(
            modelId: profile?.modelId ?? (isActive ? activeModelId : nil),
            apiKey: cred?.apiKey ?? (isActive ? activeApiKey : nil),
            baseUrl: profile?.baseUrl ?? (isActive ? activeBaseUrl : nil),
            oauthJSON: cred?.oauthJSON ?? (isActive ? activeOAuthJSON : nil),
            fetchedModels: profile?.fetchedModels ?? (isActive ? activeFetched : []),
            enabled: profile?.enabled ?? isActive
        )
    }
}
