import Foundation

/// One runnable MLX model bundle found on this Mac.
public struct MLXLocalModel: Codable, Sendable, Hashable, Identifiable {
    /// Canonical `org/repo` id where the layout reveals one, otherwise the
    /// folder name. Stable across rescans so a saved selection keeps resolving.
    public var id: String
    public var name: String
    /// Absolute path to the loadable bundle directory.
    public var path: String
    /// Human-readable provenance ("Hugging Face cache", "LM Studio", …).
    public var source: String
    public var sizeBytes: Int64
    public var modelType: String?
    public var quantizationBits: Int?

    public init(
        id: String,
        name: String,
        path: String,
        source: String,
        sizeBytes: Int64 = 0,
        modelType: String? = nil,
        quantizationBits: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.source = source
        self.sizeBytes = sizeBytes
        self.modelType = modelType
        self.quantizationBits = quantizationBits
    }

    /// Short "4-bit · 3.8 GB · qwen3" style summary for the picker.
    public var summary: String {
        var parts: [String] = []
        if let bits = quantizationBits { parts.append("\(bits)-bit") }
        if sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let type = modelType, !type.isEmpty { parts.append(type) }
        parts.append(source)
        return parts.joined(separator: " · ")
    }
}

/// Where a scan looked.
public struct MLXScanRoot: Sendable, Hashable, Identifiable {
    public enum Layout: String, Sendable {
        /// `models--org--repo/snapshots/<sha>/`
        case huggingFaceCache
        /// `publisher/repo/` — two levels of plain directories.
        case nested
    }

    public var url: URL
    public var source: String
    public var layout: Layout

    public var id: String { url.path }

    public init(url: URL, source: String, layout: Layout) {
        self.url = url
        self.source = source
        self.layout = layout
    }
}

/// Result of one scan pass.
public struct MLXScanReport: Sendable {
    public var models: [MLXLocalModel]
    public var skipped: [MLXSkippedBundle]
    public var rootsScanned: [String]

    public init(models: [MLXLocalModel], skipped: [MLXSkippedBundle], rootsScanned: [String]) {
        self.models = models
        self.skipped = skipped
        self.rootsScanned = rootsScanned
    }
}

/// Read-only discovery of MLX model bundles already on this Mac.
///
/// Nothing is copied, symlinked, or mutated in a source location — a model
/// found in the Hugging Face cache or an LM Studio folder is run in place.
/// Ported from Osaurus's `ExternalModelLocator` with the same scan roots and
/// the same minimum-shape validation (`MLXModelBundle`).
public enum MLXModelLocator {
    /// Where GrizzyBot's own Hugging Face downloads land. Shared across
    /// accounts on this Mac — the weights are large and account-independent.
    public static func downloadsDirectory() -> URL {
        AccountLayout.defaultGlobalRoot().appendingPathComponent("MLXModels", isDirectory: true)
    }

    /// The Hugging Face hub cache, honoring `HF_HUB_CACHE` / `HF_HOME`.
    public static func huggingFaceCacheDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["HF_HUB_CACHE"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// The roots scanned by default, plus any folders the user added.
    public static func defaultRoots(customFolders: [String] = []) -> [MLXScanRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [MLXScanRoot] = [
            MLXScanRoot(url: downloadsDirectory(), source: "Downloaded in GrizzyBot", layout: .nested),
            MLXScanRoot(url: huggingFaceCacheDirectory(), source: "Hugging Face cache", layout: .huggingFaceCache),
            MLXScanRoot(
                url: home.appendingPathComponent(".lmstudio/models", isDirectory: true),
                source: "LM Studio",
                layout: .nested
            ),
            MLXScanRoot(
                url: home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true),
                source: "LM Studio",
                layout: .nested
            ),
        ]
        for folder in customFolders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            roots.append(
                MLXScanRoot(
                    url: URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true),
                    source: "Custom model folder",
                    layout: .nested
                )
            )
        }
        return roots
    }

    /// Scan every root and return the valid bundles plus what was skipped.
    /// Deduplicates by canonical id, preferring the first root that supplied it
    /// (GrizzyBot's own downloads win over a cache copy of the same repo).
    public static func scan(roots: [MLXScanRoot]) -> MLXScanReport {
        var models: [MLXLocalModel] = []
        var skipped: [MLXSkippedBundle] = []
        var seenIds = Set<String>()
        var seenPaths = Set<String>()
        var scannedRoots: [String] = []

        for root in roots {
            let standardized = root.url.standardizedFileURL
            guard !scannedRoots.contains(standardized.path) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            scannedRoots.append(standardized.path)

            let candidates: [(id: String, dir: URL)]
            switch root.layout {
            case .huggingFaceCache:
                candidates = huggingFaceCandidates(root: standardized, skipped: &skipped)
            case .nested:
                candidates = nestedCandidates(root: standardized)
            }

            for candidate in candidates {
                let dirPath = candidate.dir.standardizedFileURL.path
                guard !seenPaths.contains(dirPath) else { continue }
                let diagnostic = MLXModelBundle.diagnostic(at: candidate.dir, root: standardized)
                guard diagnostic.isValid else {
                    if diagnostic.isCandidate, let reason = diagnostic.reason {
                        skipped.append(
                            MLXSkippedBundle(
                                path: dirPath,
                                reason: reason,
                                detail: diagnostic.detail ?? reason.title
                            )
                        )
                    }
                    continue
                }
                let key = candidate.id.lowercased()
                guard !seenIds.contains(key) else { continue }
                seenIds.insert(key)
                seenPaths.insert(dirPath)

                let config = MLXModelBundle.readConfig(at: candidate.dir)
                models.append(
                    MLXLocalModel(
                        id: candidate.id,
                        name: candidate.id.split(separator: "/").last.map(String.init) ?? candidate.id,
                        path: dirPath,
                        source: root.source,
                        sizeBytes: MLXModelBundle.weightBytes(at: candidate.dir),
                        modelType: config.modelType,
                        quantizationBits: config.quantizationBits
                    )
                )
            }
        }

        models.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return MLXScanReport(models: models, skipped: skipped, rootsScanned: scannedRoots)
    }

    /// Resolve a saved selection back to a bundle directory. Accepts either a
    /// canonical `org/repo` id (rescanning to find it) or an absolute path, and
    /// re-confirms `config.json` so a folder deleted out from under us fails
    /// loudly instead of loading a stale path.
    public static func bundleURL(
        forId id: String,
        customFolders: [String] = []
    ) -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let url = URL(
                fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
                isDirectory: true
            )
            return hasConfig(url) ? url : nil
        }

        let report = scan(roots: defaultRoots(customFolders: customFolders))
        guard let match = report.models.first(where: { $0.id.lowercased() == trimmed.lowercased() })
        else { return nil }
        let url = URL(fileURLWithPath: match.path, isDirectory: true)
        return hasConfig(url) ? url : nil
    }

    private static func hasConfig(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    // MARK: - Layout walkers

    /// `<root>/models--org--repo/snapshots/<sha>/` — the Hugging Face hub cache.
    /// Only the revision named by `refs/main` is used when present, so a repo
    /// with several cached revisions contributes one bundle rather than several.
    private static func huggingFaceCandidates(
        root: URL,
        skipped: inout [MLXSkippedBundle]
    ) -> [(id: String, dir: URL)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else {
            skipped.append(
                MLXSkippedBundle(
                    path: root.path,
                    reason: .unreadableRoot,
                    detail: "The Hugging Face cache folder could not be read."
                )
            )
            return []
        }

        var result: [(id: String, dir: URL)] = []
        for entry in entries {
            let folder = entry.lastPathComponent
            guard folder.hasPrefix("models--") else { continue }
            let repoId = folder
                .dropFirst("models--".count)
                .replacingOccurrences(of: "--", with: "/")
            guard repoId.contains("/") else {
                skipped.append(
                    MLXSkippedBundle(
                        path: entry.path,
                        reason: .malformedCacheFolder,
                        detail: "Cache folder name does not encode an org/repo id."
                    )
                )
                continue
            }

            let snapshots = entry.appendingPathComponent("snapshots", isDirectory: true)
            guard let revisions = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
                  !revisions.isEmpty
            else {
                skipped.append(
                    MLXSkippedBundle(
                        path: entry.path,
                        reason: .missingSnapshot,
                        detail: "No snapshots directory — the repo is not fully downloaded."
                    )
                )
                continue
            }

            let preferred = pinnedRevision(in: entry).flatMap { sha in
                revisions.first { $0.lastPathComponent == sha }
            } ?? newest(of: revisions)
            guard let snapshot = preferred else { continue }
            guard MLXModelBundle.isContained(snapshot, in: entry) else {
                skipped.append(
                    MLXSkippedBundle(
                        path: snapshot.path,
                        reason: .snapshotEscapesRoot,
                        detail: "The snapshot resolves outside its cache folder."
                    )
                )
                continue
            }
            result.append((id: repoId, dir: snapshot))
        }
        return result
    }

    /// The commit named by `refs/main`, when the cache recorded one.
    private static func pinnedRevision(in repoFolder: URL) -> String? {
        let ref = repoFolder.appendingPathComponent("refs/main")
        guard let raw = try? String(contentsOf: ref, encoding: .utf8) else { return nil }
        let sha = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private static func newest(of urls: [URL]) -> URL? {
        urls.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
    }

    /// Plain nested folders: the root itself, `<root>/<repo>`, and
    /// `<root>/<publisher>/<repo>`. Covers LM Studio's `publisher/repo` layout,
    /// GrizzyBot's own `org/repo` downloads, and a user pointing straight at a
    /// single unpacked model folder.
    private static func nestedCandidates(root: URL) -> [(id: String, dir: URL)] {
        let fm = FileManager.default

        func subdirectories(of dir: URL) -> [URL] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return items.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }

        var result: [(id: String, dir: URL)] = []
        if hasConfig(root) {
            result.append((id: root.lastPathComponent, dir: root))
            return result
        }

        for level1 in subdirectories(of: root) {
            if hasConfig(level1) {
                result.append((id: level1.lastPathComponent, dir: level1))
                continue
            }
            for level2 in subdirectories(of: level1) where hasConfig(level2) {
                result.append(
                    (id: "\(level1.lastPathComponent)/\(level2.lastPathComponent)", dir: level2)
                )
            }
        }
        return result
    }
}
