import Foundation

public enum KnowledgeSourceKind: String, Codable, Sendable {
    case folder
    case plugin
}

public struct KnowledgeSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: KnowledgeSourceKind
    /// Folder path, or plugin slug.
    public var path: String
    public var roots: [String]
    /// Empty means every bot. Otherwise only these bots may search it.
    public var grantedBotIds: [String]

    public init(
        id: String = Ids.new(),
        name: String,
        kind: KnowledgeSourceKind = .folder,
        path: String,
        roots: [String] = [],
        grantedBotIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.roots = roots
        self.grantedBotIds = grantedBotIds
    }

    public func allows(botId: String) -> Bool {
        grantedBotIds.isEmpty || grantedBotIds.contains(botId)
    }
}

public struct KnowledgeHit: Sendable, Equatable {
    public var sourceId: String
    public var sourceName: String
    public var path: String
    public var snippet: String
    public var score: Double

    public init(sourceId: String, sourceName: String, path: String, snippet: String, score: Double) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.path = path
        self.snippet = snippet
        self.score = score
    }
}

public enum KnowledgePlane {
    public static func sourcesVisible(to botId: String, from sources: [KnowledgeSource]) -> [KnowledgeSource] {
        sources.filter { $0.allows(botId: botId) }
    }

    public static func search(
        query: String,
        botId: String,
        sources: [KnowledgeSource],
        documents: [MemoryDocument],
        limit: Int = 8
    ) -> [KnowledgeHit] {
        let allowed = Set(sourcesVisible(to: botId, from: sources).map(\.id))
        let scoped = documents.filter { doc in
            doc.scope == "knowledge" && (doc.botId == nil || allowed.contains(doc.botId ?? ""))
        }
        let hits = MemoryIndex.search(documents: scoped, query: query, limit: limit, botId: nil)
        return hits.compactMap { hit in
            let source = sources.first { $0.id == documents.first { $0.path == hit.path }?.botId }
                ?? sources.first { hit.path.hasPrefix($0.path) }
            let sourceId = source?.id ?? documents.first { $0.path == hit.path }?.botId ?? ""
            guard allowed.contains(sourceId) || sourceId.isEmpty else { return nil }
            return KnowledgeHit(
                sourceId: sourceId,
                sourceName: source?.name ?? "Knowledge",
                path: hit.path,
                snippet: hit.snippet,
                score: hit.score
            )
        }
    }

    public static func indexFolder(source: KnowledgeSource, maxFiles: Int = 200) -> [MemoryDocument] {
        guard source.kind == .folder else { return [] }
        let root = (source.path as NSString).expandingTildeInPath
        var files: [URL] = []
        let fm = FileManager.default
        let roots = source.roots.isEmpty ? [root] : source.roots.map { sub in
            (root as NSString).appendingPathComponent(sub)
        }
        for folder in roots {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let url as URL in enumerator {
                if files.count >= maxFiles { break }
                let ext = url.pathExtension.lowercased()
                guard ["md", "txt", "markdown", "json", "csv"].contains(ext) else { continue }
                files.append(url)
            }
        }
        return files.compactMap { url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return MemoryDocument(
                id: "knowledge-\(source.id)-\(url.path.hashValue)",
                scope: "knowledge",
                botId: source.id,
                path: url.path,
                content: String(content.prefix(20_000))
            )
        }
    }

    public static func documents(from text: String, source: KnowledgeSource) -> [MemoryDocument] {
        let clipped = String(text.prefix(40_000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [
            MemoryDocument(
                id: "knowledge-\(source.id)",
                scope: "knowledge",
                botId: source.id,
                path: source.path,
                content: clipped
            ),
        ]
    }

    public static func isCloudPlugin(_ slug: String) -> Bool {
        let folded = slug.lowercased()
        return [
            "google-drive", "googledrive", "gdrive",
            "onedrive", "microsoft-onedrive",
            "box", "dropbox",
        ].contains(folded)
    }
}
