import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A model repository on the Hugging Face Hub.
public struct MLXHubModel: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var downloads: Int
    public var likes: Int
    public var lastModified: Date?
    public var tags: [String]
    public var pipelineTag: String?
    /// Sum of the files GrizzyBot would actually download, once resolved.
    public var sizeBytes: Int64?

    public init(
        id: String,
        downloads: Int = 0,
        likes: Int = 0,
        lastModified: Date? = nil,
        tags: [String] = [],
        pipelineTag: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.tags = tags
        self.pipelineTag = pipelineTag
        self.sizeBytes = sizeBytes
    }

    public var owner: String { id.split(separator: "/").first.map(String.init) ?? "" }
    public var name: String { id.split(separator: "/").last.map(String.init) ?? id }

    /// Quantization implied by the repo name, e.g. `…-4bit` → "4-bit".
    public var quantizationHint: String? {
        let lower = id.lowercased()
        for bits in ["2", "3", "4", "6", "8"] where lower.contains("\(bits)bit") || lower.contains("\(bits)-bit") {
            return "\(bits)-bit"
        }
        if lower.contains("bf16") { return "bf16" }
        if lower.contains("fp16") { return "fp16" }
        return nil
    }
}

/// One file inside a Hub repository.
public struct MLXHubFile: Sendable, Hashable, Codable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public enum MLXHubError: Error, LocalizedError, Sendable, Equatable {
    case message(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let code, let detail):
            switch code {
            case 401, 403:
                return "Hugging Face denied access (\(code)). This repo may be gated — accept its terms on huggingface.co and add an access token."
            case 404:
                return "That repository was not found on Hugging Face."
            case 429:
                return "Hugging Face is rate-limiting anonymous requests. Add an access token to continue."
            default:
                return "Hugging Face returned \(code). \(detail)"
            }
        }
    }
}

/// Search and file listing against the Hugging Face Hub, scoped to MLX models.
///
/// Mirrors Osaurus's `HuggingFaceService`: the same `/api/models` search, the
/// same recursive `tree/main` listing, and the same download file patterns, so
/// a repo that works in Osaurus resolves to the same file set here.
public actor MLXHuggingFaceService {
    public static let shared = MLXHuggingFaceService()

    /// Files GrizzyBot writes to disk for a model. Everything else in the repo
    /// (READMEs, ONNX/GGUF conversions, images) is left on the Hub.
    public static let downloadFilePatterns: [String] = [
        "*.json",
        "*.jinja",
        "*.txt",
        "*.model",
        "*.safetensors",
    ]

    public static let downloadExcludedFiles: Set<String> = [
        "README.md",
        ".gitattributes",
    ]

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Search

    /// Search the Hub for MLX-compatible text-generation models.
    ///
    /// An empty `query` returns the most-downloaded MLX models, which is what
    /// the picker shows before the user types anything.
    public func search(
        query: String,
        limit: Int = 40,
        token: String? = nil
    ) async throws -> [MLXHubModel] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "full", value: "1"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "mlx"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw MLXHubError.message("Could not build the Hugging Face search URL.")
        }

        struct Row: Decodable {
            let id: String
            let tags: [String]?
            let pipeline_tag: String?
            let lastModified: String?
            let downloads: Int?
            let likes: Int?
        }

        let data = try await get(url, token: token)
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw MLXHubError.message("Could not read the Hugging Face search response.")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        return rows.compactMap { row in
            let tags = row.tags?.map { $0.lowercased() } ?? []
            // The `filter=mlx` query already scopes this, but a repo tagged for
            // a non-text pipeline (audio, diffusion) can still match — those
            // are not loadable as chat models.
            if let pipeline = row.pipeline_tag?.lowercased(),
               !["text-generation", "text2text-generation", "image-text-to-text"].contains(pipeline) {
                return nil
            }
            let modified = row.lastModified.flatMap {
                formatter.date(from: $0) ?? plainFormatter.date(from: $0)
            }
            return MLXHubModel(
                id: row.id,
                downloads: row.downloads ?? 0,
                likes: row.likes ?? 0,
                lastModified: modified,
                tags: tags,
                pipelineTag: row.pipeline_tag
            )
        }
    }

    // MARK: - Files

    /// Every file in the repo, recursively.
    public func allFiles(repoId: String, token: String? = nil) async throws -> [MLXHubFile] {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("/") else {
            throw MLXHubError.message("Expected a Hugging Face repo id like `mlx-community/Qwen3-4B-4bit`.")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(trimmed)/tree/main"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components.url else {
            throw MLXHubError.message("Could not build the Hugging Face file-listing URL.")
        }

        struct Node: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let path: String
            let type: String?
            let size: Int64?
            let lfs: LFS?
            var bestSize: Int64 { lfs?.size ?? size ?? 0 }
        }

        let data = try await get(url, token: token)
        guard let nodes = try? JSONDecoder().decode([Node].self, from: data) else {
            throw MLXHubError.message("Could not read the Hugging Face file listing.")
        }
        return nodes
            .filter { ($0.type ?? "file") == "file" }
            .map { MLXHubFile(path: $0.path, size: $0.bestSize) }
    }

    /// The subset of `allFiles` that GrizzyBot downloads for a model.
    public func downloadFiles(repoId: String, token: String? = nil) async throws -> [MLXHubFile] {
        let files = try await allFiles(repoId: repoId, token: token)
        return Self.filterDownloadable(files)
    }

    /// Total bytes GrizzyBot would write for `repoId`.
    public func estimateSize(repoId: String, token: String? = nil) async -> Int64? {
        guard let files = try? await downloadFiles(repoId: repoId, token: token), !files.isEmpty else {
            return nil
        }
        return files.reduce(0) { $0 + $1.size }
    }

    /// True when the repo's file list is a complete, loadable MLX bundle.
    public func isLoadableBundle(repoId: String, token: String? = nil) async -> Bool {
        guard let files = try? await allFiles(repoId: repoId, token: token) else { return false }
        return Self.filesFormLoadableBundle(files)
    }

    // MARK: - Pure helpers

    public static func filterDownloadable(_ files: [MLXHubFile]) -> [MLXHubFile] {
        let matchers = downloadFilePatterns.compactMap { MLXGlob($0) }
        return files.filter { file in
            let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            guard !downloadExcludedFiles.contains(name) else { return false }
            return matchers.contains { $0.matches(name) }
        }
    }

    /// The Hub-side mirror of `MLXModelBundle.diagnostic`: config + tokenizer +
    /// safetensors weights. Checked before a download starts so the user is not
    /// told to wait on 4 GB that will never load.
    public static func filesFormLoadableBundle(_ files: [MLXHubFile]) -> Bool {
        var hasConfig = false
        var hasWeights = false
        var hasTokenizer = false
        for file in files {
            let name = (file.path.split(separator: "/").last.map(String.init) ?? file.path).lowercased()
            if name == "config.json" { hasConfig = true }
            if name.hasSuffix(".safetensors") { hasWeights = true }
            if ["tokenizer.json", "tokenizer.model", "spiece.model", "vocab.json", "vocab.txt"].contains(name) {
                hasTokenizer = true
            }
        }
        return hasConfig && hasWeights && hasTokenizer
    }

    /// Reject `..`, absolute paths, and empty components in a remote file path.
    public static func normalizedRemotePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        var components: [String] = []
        for raw in trimmed.split(separator: "/") {
            let component = String(raw)
            guard component != ".", component != ".." , !component.isEmpty else { return nil }
            components.append(component)
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// Where a remote file lands under `directory`, or `nil` if the path would
    /// escape it.
    public static func destinationURL(forRemotePath path: String, under directory: URL) -> URL? {
        guard let safe = normalizedRemotePath(path) else { return nil }
        let base = directory.standardizedFileURL
        let destination = safe
            .split(separator: "/")
            .reduce(base) { $0.appendingPathComponent(String($1), isDirectory: false) }
            .standardizedFileURL
        guard destination.pathComponents.count > base.pathComponents.count,
              Array(destination.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents
        else { return nil }
        return destination
    }

    public static func fileURL(repoId: String, path: String) -> URL? {
        guard let safe = normalizedRemotePath(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoId)/resolve/main/\(safe)"
        return components.url
    }

    // MARK: - Transport

    private func get(_ url: URL, token: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GrizzyBot", forHTTPHeaderField: "User-Agent")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MLXHubError.message("Hugging Face returned an unexpected response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw MLXHubError.http(http.statusCode, body)
        }
        return data
    }
}

/// Minimal glob matcher for the `*.safetensors` style download patterns.
public struct MLXGlob: Sendable {
    private let pattern: String

    public init?(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.pattern = trimmed
    }

    public func matches(_ text: String) -> Bool {
        fnmatch(pattern, text, 0) == 0
    }
}
