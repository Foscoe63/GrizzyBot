import Foundation

/// The in-app MLX provider: models that run on this Mac's GPU inside
/// GrizzyBot, rather than being served over HTTP by Ollama / LM Studio / an
/// MLX server.
///
/// It shares the provider plumbing with the HTTP-backed local providers in
/// `LocalProviders` — it appears in the same rail, has an enable toggle, and
/// persists its selection in the same `ModelProviderProfile` — but it has no
/// base URL, and `LocalProviders.isLocal` deliberately does not claim it so
/// URL normalization and LAN probing skip it.
public enum MLXProvider {
    public static let id = "localmlx"
    public static let name = "Local MLX"
    public static let billing =
        "Runs on this Mac's Apple Silicon GPU inside GrizzyBot. Nothing leaves the machine and there are no model charges."

    /// Sentinel used where the plumbing insists on a base URL. Nothing dials
    /// it; `MLXChatClient` keys off the provider and reads the bundle path out
    /// of `ModelEndpoint.model`.
    public static let inProcessBaseURL = "mlx://in-process"

    public static func isMLX(_ provider: String?) -> Bool {
        provider?.trimmingCharacters(in: .whitespacesAndNewlines) == id
    }

    public static func catalogEntry() -> CatalogEntry {
        CatalogEntry(
            provider: id,
            providerName: name,
            id: "\(id)/default",
            label: "Run an MLX model in GrizzyBot",
            billing: billing,
            auth: .apiKey,
            subscription: false,
            kind: .local,
            defaultBaseUrl: nil,
            supportsBaseUrl: false
        )
    }

    /// True when this Mac can run MLX at all. MLX is Apple Silicon only; on
    /// Intel the provider is shown disabled with an explanation rather than
    /// failing at load time.
    public static var isSupportedHardware: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public static let unsupportedHardwareMessage =
        "Local MLX needs an Apple Silicon Mac. Use Ollama, LM Studio, or a remote provider on this machine."

    /// Turn a discovered bundle into the `LocalModelRef` the provider profile
    /// and chat picker store. The id is the absolute bundle path, so a model
    /// keeps resolving even if it is later renamed on the Hub or the same repo
    /// exists in two caches.
    public static func modelRef(for model: MLXLocalModel) -> LocalModelRef {
        LocalModelRef(id: model.path, label: "\(model.id) — \(model.summary)")
    }
}

/// Non-secret Local MLX preferences: the extra folders to scan and the models
/// that were found there.
///
/// Kept in `UserDefaults` rather than the workspace because they describe this
/// Mac (where model weights live on disk), not the user's account — the same
/// split Osaurus uses for its external-model import settings.
public enum MLXSettingsStore {
    public static let customFoldersKey = "MLXCustomModelFolders"
    public static let scanHuggingFaceCacheKey = "MLXScanHuggingFaceCache"
    public static let scanLMStudioKey = "MLXScanLMStudio"

    private static var defaults: UserDefaults { .standard }

    public static var customFolders: [String] {
        get { defaults.stringArray(forKey: customFoldersKey) ?? [] }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            defaults.set(cleaned, forKey: customFoldersKey)
        }
    }

    public static var scansHuggingFaceCache: Bool {
        get { defaults.object(forKey: scanHuggingFaceCacheKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: scanHuggingFaceCacheKey) }
    }

    public static var scansLMStudio: Bool {
        get { defaults.object(forKey: scanLMStudioKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: scanLMStudioKey) }
    }

    public static func addCustomFolder(_ path: String) {
        customFolders = customFolders + [path]
    }

    public static func removeCustomFolder(_ path: String) {
        customFolders = customFolders.filter { $0 != path }
    }

    /// The roots a scan should walk, honoring the two source toggles.
    public static func activeRoots() -> [MLXScanRoot] {
        MLXModelLocator.defaultRoots(customFolders: customFolders).filter { root in
            switch root.source {
            case "Hugging Face cache": return scansHuggingFaceCache
            case "LM Studio": return scansLMStudio
            default: return true
            }
        }
    }

    /// Scan every active root. Safe to call off the main actor; it only touches
    /// the file system.
    public static func scan() -> MLXScanReport {
        MLXModelLocator.scan(roots: activeRoots())
    }
}
