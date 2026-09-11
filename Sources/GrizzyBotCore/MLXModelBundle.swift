import Foundation

/// Why a candidate directory was not registered as a runnable MLX bundle.
///
/// Mirrors Osaurus's `ExternalModelLocator.SkipReason` so the two apps agree
/// on what "a loadable MLX model folder" means.
public enum MLXSkipReason: String, Codable, Sendable, Equatable {
    case unreadableRoot
    case malformedCacheFolder
    case missingSnapshot
    case snapshotEscapesRoot
    case missingConfig
    case missingTokenizer
    case missingSafetensors
    case ggufOnly
    case symlinkEscapesRoot

    public var title: String {
        switch self {
        case .unreadableRoot: return "Folder unreadable"
        case .malformedCacheFolder: return "Malformed cache folder"
        case .missingSnapshot: return "Snapshot missing"
        case .snapshotEscapesRoot: return "Snapshot outside folder"
        case .missingConfig: return "config.json missing"
        case .missingTokenizer: return "Tokenizer missing"
        case .missingSafetensors: return "Safetensors missing"
        case .ggufOnly: return "GGUF-only bundle"
        case .symlinkEscapesRoot: return "Symlink escapes folder"
        }
    }
}

/// The verdict for one candidate directory.
public struct MLXBundleDiagnostic: Sendable, Equatable {
    public let isValid: Bool
    public let reason: MLXSkipReason?
    public let detail: String?
    /// True when the directory looked like an attempted model bundle at all —
    /// used to decide whether it is worth reporting to the user as "skipped"
    /// rather than silently ignoring an unrelated folder.
    public let isCandidate: Bool

    public init(isValid: Bool, reason: MLXSkipReason?, detail: String?, isCandidate: Bool) {
        self.isValid = isValid
        self.reason = reason
        self.detail = detail
        self.isCandidate = isCandidate
    }
}

/// One directory that was inspected and rejected.
public struct MLXSkippedBundle: Sendable, Equatable, Identifiable {
    public let path: String
    public let reason: MLXSkipReason
    public let detail: String

    public var id: String { path }

    public init(path: String, reason: MLXSkipReason, detail: String) {
        self.path = path
        self.reason = reason
        self.detail = detail
    }
}

/// Validation of an on-disk MLX (safetensors) model bundle.
///
/// A bundle is loadable when it has `config.json`, a recognized tokenizer, and
/// at least one `*.safetensors` weight file. GGUF-only directories are
/// rejected — the MLX runtime cannot load them. Symlinked files must resolve
/// to a target that stays under the scan root, so a poisoned cache entry
/// cannot point the loader at an arbitrary path.
public enum MLXModelBundle {
    private enum Probe {
        case present
        case missing
        case escapesRoot
    }

    public static func isBundle(_ dir: URL, root: URL) -> Bool {
        diagnostic(at: dir, root: root).isValid
    }

    public static func diagnostic(
        at dir: URL,
        root: URL,
        enforceSymlinkContainment: Bool = true
    ) -> MLXBundleDiagnostic {
        let fm = FileManager.default

        func probe(_ name: String) -> Probe {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return .missing }
            guard enforceSymlinkContainment else { return .present }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return isContained(resolved, in: root) ? .present : .escapesRoot
        }

        func hasAny(_ probes: [Probe]) -> Bool {
            probes.contains { $0 == .present || $0 == .escapesRoot }
        }

        let config = probe("config.json")
        let tokenizerJSON = probe("tokenizer.json")
        let merges = probe("merges.txt")
        let vocabJSON = probe("vocab.json")
        let vocabTXT = probe("vocab.txt")
        let tokenizerModel = probe("tokenizer.model")
        let spieceModel = probe("spiece.model")
        let tokenizerProbes = [tokenizerJSON, merges, vocabJSON, vocabTXT, tokenizerModel, spieceModel]

        var sawSafetensors = false
        var sawGGUF = false
        var weightEscapesRoot = false
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items {
                if item.pathExtension == "gguf" {
                    sawGGUF = true
                    continue
                }
                guard item.pathExtension == "safetensors" else { continue }
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL
                if !enforceSymlinkContainment || isContained(resolved, in: root) {
                    sawSafetensors = true
                } else {
                    weightEscapesRoot = true
                }
            }
        }

        let isCandidate =
            hasAny([config]) || hasAny(tokenizerProbes) || sawSafetensors || sawGGUF || weightEscapesRoot

        if config == .escapesRoot {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "config.json resolves outside the scanned folder.",
                isCandidate: true
            )
        }
        guard config == .present else {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .missingConfig,
                detail: "config.json is required for MLX model discovery.",
                isCandidate: isCandidate
            )
        }

        if tokenizerProbes.contains(.escapesRoot) {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "A tokenizer file resolves outside the scanned folder.",
                isCandidate: true
            )
        }
        let hasTokenizer =
            tokenizerJSON == .present
            || (merges == .present && (vocabJSON == .present || vocabTXT == .present))
            || tokenizerModel == .present
            || spieceModel == .present
        guard hasTokenizer else {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .missingTokenizer,
                detail: "Expected tokenizer.json, BPE merges/vocab files, tokenizer.model, or spiece.model.",
                isCandidate: true
            )
        }

        if weightEscapesRoot {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .symlinkEscapesRoot,
                detail: "A safetensors file resolves outside the scanned folder.",
                isCandidate: true
            )
        }
        if sawSafetensors {
            return MLXBundleDiagnostic(isValid: true, reason: nil, detail: nil, isCandidate: true)
        }
        if sawGGUF {
            return MLXBundleDiagnostic(
                isValid: false,
                reason: .ggufOnly,
                detail: "GGUF files are present, but MLX requires safetensors weights.",
                isCandidate: true
            )
        }
        return MLXBundleDiagnostic(
            isValid: false,
            reason: .missingSafetensors,
            detail: "Expected at least one .safetensors weight file.",
            isCandidate: true
        )
    }

    /// True when `url` is `directory` itself or lives underneath it. Compares
    /// resolved path components, so `/a/bc` is not treated as inside `/a/b`.
    public static func isContained(_ url: URL, in directory: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count >= base.count else { return false }
        return Array(target.prefix(base.count)) == base
    }

    // MARK: - config.json facts

    /// The few `config.json` fields worth showing in the picker.
    public struct BundleConfig: Sendable, Equatable {
        public var modelType: String?
        public var quantizationBits: Int?
        public var maxPositionEmbeddings: Int?
    }

    public static func readConfig(at dir: URL) -> BundleConfig {
        let url = dir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return BundleConfig() }

        var bits: Int?
        if let quant = object["quantization"] as? [String: Any] {
            bits = quant["bits"] as? Int
        }
        return BundleConfig(
            modelType: object["model_type"] as? String,
            quantizationBits: bits,
            maxPositionEmbeddings: object["max_position_embeddings"] as? Int
        )
    }

    /// Sum of the `.safetensors` bytes in `dir` (non-recursive, matching the
    /// flat layout MLX bundles use).
    public static func weightBytes(at dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for item in items where item.pathExtension == "safetensors" {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
