import Foundation

/// One model on disk that Splash can serve.
///
/// Splash names a model by Hugging Face id (`org/repo` for an MLX bundle or a
/// Splash package, `org/repo:VARIANT` for a GGUF), and the API's `model` field
/// must match what `splash serve --model` was given. So `id` is that name, and
/// `path` records where the files were found.
public struct SplashLocalModel: Codable, Sendable, Hashable, Identifiable {
    public enum Format: String, Codable, Sendable {
        case mlx = "MLX"
        case gguf = "GGUF"
        case splashPackage = "Splash package"
    }

    public var id: String
    public var path: String
    public var source: String
    public var format: Format
    public var sizeBytes: Int64

    public init(id: String, path: String, source: String, format: Format, sizeBytes: Int64) {
        self.id = id
        self.path = path
        self.source = source
        self.format = format
        self.sizeBytes = sizeBytes
    }

    public var summary: String {
        var parts = [format.rawValue]
        if sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        parts.append(source)
        return parts.joined(separator: " · ")
    }
}

public struct SplashScanReport: Sendable {
    public var models: [SplashLocalModel]
    public var rootsScanned: [String]
}

/// Read-only discovery of models Splash can run, in the same places Local MLX
/// looks: the Hugging Face cache, LM Studio's folder, and folders the user adds.
public enum SplashModelLocator {
    /// Splash is tuned for specific model families rather than arbitrary
    /// architectures, so a folder of other models is not offered.
    public static func isSupported(_ id: String) -> Bool {
        let lower = id.lowercased()
        return ["qwen3.8", "qwen3.6", "splash", "bonsai"].contains { lower.contains($0) }
    }

    /// `Qwen3.8-27B-UD-Q4_K_M.gguf` → `UD-Q4_K_M`. Nil for projector files and
    /// names with no recognizable quantization.
    public static func ggufVariant(fromFileName name: String) -> String? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".gguf"), !lower.contains("mmproj") else { return nil }
        let stem = String(name.dropLast(5))
        let pattern = #"((?:UD-)?(?:I?Q\d(?:_[A-Z0-9]+)*|BF16|F16|PQ\d_\d))(?:-\d{5}-of-\d{5})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem)
        else { return nil }
        return String(stem[range])
    }

    public static func scan(roots: [MLXScanRoot]) -> SplashScanReport {
        var models: [SplashLocalModel] = []
        var seen = Set<String>()
        var scanned: [String] = []
        let fm = FileManager.default

        func add(_ model: SplashLocalModel) {
            guard isSupported(model.id), seen.insert(model.id.lowercased()).inserted else { return }
            models.append(model)
        }

        for root in roots {
            let base = root.url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue,
                  !scanned.contains(base.path)
            else { continue }
            scanned.append(base.path)

            for (id, dir) in candidates(in: base, layout: root.layout) {
                for model in bundles(id: id, dir: dir, source: root.source) { add(model) }
            }
        }
        models.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return SplashScanReport(models: models, rootsScanned: scanned)
    }

    // MARK: - Layouts

    private static func subdirectories(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func candidates(in root: URL, layout: MLXScanRoot.Layout) -> [(String, URL)] {
        switch layout {
        case .huggingFaceCache:
            return subdirectories(of: root).compactMap { entry in
                let name = entry.lastPathComponent
                guard name.hasPrefix("models--") else { return nil }
                let repo = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
                guard repo.contains("/") else { return nil }
                let snapshots = subdirectories(of: entry.appendingPathComponent("snapshots"))
                let newest = snapshots.max { lhs, rhs in
                    modified(lhs) < modified(rhs)
                }
                return newest.map { (repo, $0) }
            }
        case .nested:
            var result: [(String, URL)] = []
            for level1 in subdirectories(of: root) {
                result.append((level1.lastPathComponent, level1))
                for level2 in subdirectories(of: level1) {
                    result.append(("\(level1.lastPathComponent)/\(level2.lastPathComponent)", level2))
                }
            }
            return result
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - One folder

    private static func bundles(id: String, dir: URL, source: String) -> [SplashLocalModel] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        func size(_ url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        var result: [SplashLocalModel] = []

        // GGUF: one model per quantization; shards of one variant count once.
        var variants: [String: Int64] = [:]
        for file in files where file.pathExtension.lowercased() == "gguf" {
            guard let variant = ggufVariant(fromFileName: file.lastPathComponent) else { continue }
            variants[variant, default: 0] += size(file)
        }
        for (variant, bytes) in variants {
            result.append(
                SplashLocalModel(
                    id: "\(id):\(variant)",
                    path: dir.path,
                    source: source,
                    format: .gguf,
                    sizeBytes: bytes
                )
            )
        }

        // MLX bundle or Splash package: config.json beside safetensors weights.
        let weights = files.filter { $0.pathExtension.lowercased() == "safetensors" }
        if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path), !weights.isEmpty {
            let isPackage = id.lowercased().contains("splash")
            result.append(
                SplashLocalModel(
                    id: id,
                    path: dir.path,
                    source: source,
                    format: isPackage ? .splashPackage : .mlx,
                    sizeBytes: weights.reduce(0) { $0 + size($1) }
                )
            )
        }
        return result
    }
}

/// Non-secret Splash preferences, kept in `UserDefaults` like the Local MLX
/// ones: they describe where weights live on this Mac, not the account.
public enum SplashSettingsStore {
    public static let customFoldersKey = "SplashCustomModelFolders"
    public static let scanHuggingFaceCacheKey = "SplashScanHuggingFaceCache"
    public static let scanLMStudioKey = "SplashScanLMStudio"

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

    public static func addCustomFolder(_ path: String) { customFolders = customFolders + [path] }
    public static func removeCustomFolder(_ path: String) {
        customFolders = customFolders.filter { $0 != path }
    }

    /// GrizzyBot's own MLX downloads are not Splash's business, so that root is
    /// left out.
    public static func activeRoots() -> [MLXScanRoot] {
        MLXModelLocator.defaultRoots(customFolders: customFolders).filter { root in
            switch root.source {
            case "Downloaded in GrizzyBot": return false
            case "Hugging Face cache": return scansHuggingFaceCache
            case "LM Studio": return scansLMStudio
            default: return true
            }
        }
    }

    public static func scan() -> SplashScanReport {
        SplashModelLocator.scan(roots: activeRoots())
    }

    /// The command that serves `model`. A cache in a non-default place is
    /// passed through `HF_HUB_CACHE`, which is how Splash is told where to look.
    public static func serveCommand(for model: SplashLocalModel?, fallbackId: String) -> String {
        let id = model?.id ?? fallbackId
        var prefix = ""
        if let model, model.source == "Hugging Face cache" {
            let cache = MLXModelLocator.huggingFaceCacheDirectory().path
            let standard = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub").path
            if cache != standard { prefix = "HF_HUB_CACHE=\(shellQuote(cache)) " }
        }
        return "\(prefix)splash serve --model \(shellQuote(id))"
    }

    private static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil
            ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
