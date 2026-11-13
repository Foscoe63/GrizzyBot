import Foundation
import NaturalLanguage

private struct KChunk: Sendable {
    var ordinal: Int
    var relPath: String
    var absPath: String
    var title: String
    var text: String
    var tf: [String: Int]
    var length: Int
    var links: [String]
    var vector: [Float]?
}

private struct KFile: Sendable {
    var mtime: Date
    var size: Int
    var chunks: [KChunk]
}

private struct KSourceIndex: Sendable {
    var signature: String
    var files: [String: KFile] = [:]
    var stats: KnowledgeIndexStats
    var df: [String: Int] = [:]
    var totalLength = 0
    var chunkCount = 0
    /// Lowercased note name → relative paths, for `[[wikilinks]]`.
    var names: [String: [String]] = [:]
}

/// Cached, chunked, hybrid (keyword + semantic) search over the knowledge sources.
///
/// Folder sources are re-walked on every search, but only files whose size or modification
/// time changed are read again, so an unchanged vault costs a directory stat pass.
/// Embeddings are averaged on-device NaturalLanguage word vectors; if it is unavailable
/// search silently falls back to keyword ranking.
public actor KnowledgeIndexer {
    public static let defaultMaxFiles = 5_000
    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "json", "csv"]
    private static let maxFileBytes = 2_000_000
    private static let maxChunkChars = 1_500
    private static let maxSemanticChunksPerSource = 10_000
    private static let rrfK = 60.0
    private static let semanticFloor: Float = 0.5
    /// Semantic rank counts for less than keyword rank: the on-device model is a coarse signal.
    private static let semanticWeight = 0.6

    private let maxFiles: Int
    private let useSemantic: Bool
    private var indexes: [String: KSourceIndex] = [:]
    private var embedder: NLEmbedding?  // word vectors
    private var embedderTried = false

    public init(maxFiles: Int = KnowledgeIndexer.defaultMaxFiles, semantic: Bool = true) {
        self.maxFiles = maxFiles
        self.useSemantic = semantic
    }

    // MARK: - Indexing

    public func stats(for sourceId: String) -> KnowledgeIndexStats? {
        indexes[sourceId]?.stats
    }

    public func drop(_ sourceId: String) {
        indexes[sourceId] = nil
    }

    /// Brings a folder source's index up to date. `force` discards the cache first.
    @discardableResult
    public func refresh(_ source: KnowledgeSource, force: Bool = false) -> KnowledgeIndexStats {
        guard source.kind == .folder else {
            return indexes[source.id]?.stats ?? KnowledgeIndexStats(sourceId: source.id)
        }
        let base = KnowledgePaths.canonical(source.path)
        var notes: [String] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let stats = KnowledgeIndexStats(sourceId: source.id, notes: ["Folder not found: \(source.path)"])
            indexes[source.id] = KSourceIndex(signature: "", stats: stats)
            return stats
        }

        let (roots, rejected) = KnowledgePaths.resolveRoots(source.roots, base: base)
        for entry in rejected {
            notes.append("Ignored subfolder “\(entry)”: it must stay inside the source folder.")
        }
        let signature = ([base.path] + roots.map(\.url.path)).joined(separator: "\u{1F}")
        var index = indexes[source.id]
        if force || index == nil || index?.signature != signature {
            index = KSourceIndex(signature: signature, stats: KnowledgeIndexStats(sourceId: source.id))
        }
        var current = index!

        var seen = Set<String>()
        var files: [String: KFile] = [:]
        var reparsed = 0
        var overLimit = 0, tooLarge = 0, unreadable = 0, outside = 0
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]

        for root in roots {
            if !fm.fileExists(atPath: root.url.path) {
                notes.append("Subfolder “\(root.name)” not found.")
                continue
            }
            guard let walker = fm.enumerator(
                at: root.url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker {
                guard Self.textExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard KnowledgePaths.contains(base, resolved) else {
                    outside += 1
                    continue
                }
                let key = resolved.path
                guard seen.insert(key).inserted else { continue }
                guard let values = try? resolved.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                if files.count >= maxFiles {
                    overLimit += 1
                    continue
                }
                let size = values.fileSize ?? 0
                if size > Self.maxFileBytes {
                    tooLarge += 1
                    continue
                }
                let mtime = values.contentModificationDate ?? .distantPast
                if let old = current.files[key], old.mtime == mtime, old.size == size {
                    files[key] = old
                    continue
                }
                guard let data = try? Data(contentsOf: resolved),
                      let raw = String(data: data, encoding: .utf8) else {
                    unreadable += 1
                    continue
                }
                let rel = String(key.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                files[key] = KFile(mtime: mtime, size: size, chunks: makeChunks(rel: rel, abs: key, raw: raw, markdown: Self.isMarkdown(resolved)))
                reparsed += 1
            }
        }

        if overLimit > 0 {
            notes.append("\(overLimit) file(s) over the \(maxFiles)-file limit were not indexed. Narrow the subfolders to include them.")
        }
        if tooLarge > 0 { notes.append("\(tooLarge) file(s) over 2 MB were skipped.") }
        if unreadable > 0 { notes.append("\(unreadable) file(s) could not be read as UTF-8 text.") }
        if outside > 0 { notes.append("\(outside) file(s) resolving outside the folder (symlinks) were skipped.") }

        let changed = reparsed > 0 || Set(files.keys) != Set(current.files.keys) || force
        current.files = files
        if changed || current.chunkCount == 0 { Self.rebuildAggregates(&current) }
        current.stats = KnowledgeIndexStats(
            sourceId: source.id,
            indexedFiles: files.count,
            skippedFiles: overLimit + tooLarge + unreadable + outside,
            reparsedFiles: reparsed,
            chunks: current.chunkCount,
            semanticChunks: files.values.reduce(0) { $0 + $1.chunks.filter { $0.vector != nil }.count },
            notes: notes
        )
        indexes[source.id] = current
        return current.stats
    }

    /// Replaces a plugin source's corpus with freshly synced text.
    public func setPluginText(_ text: String, for source: KnowledgeSource) {
        let clipped = String(text.prefix(40_000))
        var index = KSourceIndex(signature: "plugin", stats: KnowledgeIndexStats(sourceId: source.id))
        let chunks = makeChunks(rel: source.path, abs: source.path, raw: clipped, markdown: true, fallbackTitle: source.name)
        if !chunks.isEmpty {
            index.files[source.path] = KFile(mtime: .now, size: clipped.utf8.count, chunks: chunks)
        }
        Self.rebuildAggregates(&index)
        index.stats = KnowledgeIndexStats(
            sourceId: source.id,
            indexedFiles: chunks.isEmpty ? 0 : 1,
            reparsedFiles: 1,
            chunks: index.chunkCount,
            semanticChunks: chunks.filter { $0.vector != nil }.count
        )
        indexes[source.id] = index
    }

    // MARK: - Search

    /// `botId == nil` searches as the owner: every enabled source, ignoring bot grants.
    public func search(
        query: String,
        botId: String?,
        sources: [KnowledgeSource],
        limit: Int = 8
    ) -> [KnowledgeHit] {
        let queryTokens = Array(Set(MemoryIndex.tokenize(query)))
        guard !queryTokens.isEmpty else { return [] }
        let active = sources.filter { source in
            guard source.enabled else { return false }
            guard let botId else { return true }
            return source.allows(botId: botId)
        }
        for source in active where source.kind == .folder { refresh(source) }
        let scoped: [(source: KnowledgeSource, index: KSourceIndex)] = active.compactMap { source in
            indexes[source.id].map { (source, $0) }
        }
        guard !scoped.isEmpty else { return [] }

        var df: [String: Int] = [:]
        var total = 0
        var totalLength = 0
        for (_, index) in scoped {
            total += index.chunkCount
            totalLength += index.totalLength
            for term in queryTokens { df[term, default: 0] += index.df[term] ?? 0 }
        }
        guard total > 0 else { return [] }
        let avgLength = Double(max(1, totalLength)) / Double(total)
        let n = Double(total)
        let k1 = 1.5, b = 0.75

        struct Candidate {
            var source: KnowledgeSource
            var chunk: KChunk
            var keyword = 0.0
            var cosine: Float?
            var keywordRank: Int?
            var semanticRank: Int?
        }
        func key(_ s: KnowledgeSource, _ c: KChunk) -> String { "\(s.id)|\(c.absPath)|\(c.ordinal)" }

        let queryVector = embed(query)
        var candidates: [String: Candidate] = [:]
        var keyword: [(String, Double)] = []
        var semantic: [(String, Float)] = []

        for (source, index) in scoped {
            for file in index.files.values {
                for chunk in file.chunks {
                    var bm25 = 0.0
                    for term in queryTokens {
                        let freq = Double(chunk.tf[term] ?? 0)
                        guard freq > 0 else { continue }
                        let docsWith = Double(df[term] ?? 0)
                        let idf = log((n - docsWith + 0.5) / (docsWith + 0.5) + 1)
                        let denom = freq + k1 * (1 - b + b * Double(max(1, chunk.length)) / avgLength)
                        bm25 += idf * (freq * (k1 + 1)) / denom
                    }
                    var cosine: Float?
                    if let queryVector, let vector = chunk.vector, vector.count == queryVector.count {
                        var dot: Float = 0
                        for i in 0..<vector.count { dot += vector[i] * queryVector[i] }
                        if dot >= Self.semanticFloor { cosine = dot }
                    }
                    guard bm25 > 0 || cosine != nil else { continue }
                    let id = key(source, chunk)
                    candidates[id] = Candidate(source: source, chunk: chunk, keyword: bm25, cosine: cosine)
                    if bm25 > 0 { keyword.append((id, bm25)) }
                    if let cosine { semantic.append((id, cosine)) }
                }
            }
        }

        keyword.sort { $0.1 > $1.1 }
        semantic.sort { $0.1 > $1.1 }
        for (rank, entry) in keyword.prefix(60).enumerated() { candidates[entry.0]?.keywordRank = rank }
        for (rank, entry) in semantic.prefix(60).enumerated() { candidates[entry.0]?.semanticRank = rank }

        let maxFused = (queryVector != nil ? 1 + Self.semanticWeight : 1.0) / (Self.rrfK + 1)
        var fused: [(id: String, score: Double)] = candidates.compactMap { id, c in
            var score = 0.0
            if let r = c.keywordRank { score += 1 / (Self.rrfK + Double(r) + 1) }
            if let r = c.semanticRank { score += Self.semanticWeight / (Self.rrfK + Double(r) + 1) }
            return score > 0 ? (id, score) : nil
        }
        fused.sort { $0.score > $1.score }

        // Notes the best sections link to are likely relevant too: nudge their sections up.
        var boosted = Set<String>()
        for top in fused.prefix(3) {
            guard let c = candidates[top.id], let index = indexes[c.source.id] else { continue }
            for link in c.chunk.links {
                for rel in index.names[link] ?? [] { boosted.insert("\(c.source.id)|\(rel)") }
            }
        }
        if !boosted.isEmpty {
            fused = fused.map { entry in
                guard let c = candidates[entry.id], boosted.contains("\(c.source.id)|\(c.chunk.relPath)") else { return entry }
                return (entry.id, entry.score * 1.2)
            }
            fused.sort { $0.score > $1.score }
        }

        var perFile: [String: Int] = [:]
        var hits: [KnowledgeHit] = []
        for entry in fused {
            guard let c = candidates[entry.id] else { continue }
            let fileKey = "\(c.source.id)|\(c.chunk.absPath)"
            if perFile[fileKey, default: 0] >= 2 { continue }
            perFile[fileKey, default: 0] += 1
            let index = indexes[c.source.id]
            let linked = c.chunk.links.flatMap { index?.names[$0] ?? [] }
            hits.append(
                KnowledgeHit(
                    sourceId: c.source.id,
                    sourceName: c.source.name,
                    path: c.chunk.absPath,
                    snippet: Self.snippet(c.chunk.text, tokens: queryTokens),
                    score: min(1, entry.score / maxFused),
                    relativePath: c.chunk.relPath,
                    title: c.chunk.title,
                    keywordScore: c.keyword,
                    semanticScore: c.cosine.map(Double.init),
                    linked: Array(NSOrderedSet(array: linked).array.compactMap { $0 as? String }.prefix(5))
                )
            )
            if hits.count >= limit { break }
        }
        return hits
    }

    // MARK: - Helpers

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private func makeChunks(rel: String, abs: String, raw: String, markdown: Bool, fallbackTitle: String? = nil) -> [KChunk] {
        let (body, frontTitle) = markdown ? KnowledgeMarkdown.stripFrontmatter(raw) : (raw.replacingOccurrences(of: "\r\n", with: "\n"), nil)
        let fileName = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        let title = frontTitle ?? fallbackTitle ?? fileName
        let sections = KnowledgeMarkdown.sections(fileTitle: title, body: body, markdown: markdown, maxChars: Self.maxChunkChars)
        var vectorBudget = Self.maxSemanticChunksPerSource
        var out: [KChunk] = []
        for (ordinal, section) in sections.enumerated() {
            let tokens = MemoryIndex.tokenize(section.title + " " + section.text)
            guard !tokens.isEmpty else { continue }
            var tf: [String: Int] = [:]
            for token in tokens { tf[token, default: 0] += 1 }
            var vector: [Float]?
            if vectorBudget > 0 {
                vector = embed(section.title + ". " + section.text)
                if vector != nil { vectorBudget -= 1 }
            }
            out.append(
                KChunk(
                    ordinal: ordinal,
                    relPath: rel,
                    absPath: abs,
                    title: section.title,
                    text: section.text,
                    tf: tf,
                    length: tokens.count,
                    links: section.links,
                    vector: vector
                )
            )
        }
        return out
    }

    private static func rebuildAggregates(_ index: inout KSourceIndex) {
        index.df = [:]
        index.totalLength = 0
        index.chunkCount = 0
        index.names = [:]
        for file in index.files.values {
            guard let first = file.chunks.first else { continue }
            let name = ((first.relPath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            index.names[name, default: []].append(first.relPath)
            for chunk in file.chunks {
                index.chunkCount += 1
                index.totalLength += chunk.length
                for term in chunk.tf.keys { index.df[term, default: 0] += 1 }
            }
        }
    }

    /// Mean of the on-device word vectors for the text's words, unit length. Apple's sentence
    /// model scored unrelated notes above on-topic ones in testing, so words are pooled instead.
    private func embed(_ text: String) -> [Float]? {
        guard useSemantic else { return nil }
        if !embedderTried {
            embedderTried = true
            embedder = NLEmbedding.wordEmbedding(for: .english)
        }
        guard let embedder else { return nil }
        var sum = [Double](repeating: 0, count: embedder.dimension)
        var known = 0
        for word in MemoryIndex.tokenize(String(text.prefix(2_000))) where word.count >= 3 {
            guard let vector = embedder.vector(for: word), vector.count == sum.count else { continue }
            for i in sum.indices { sum[i] += vector[i] }
            known += 1
        }
        guard known > 0 else { return nil }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }

    private static func snippet(_ text: String, tokens: [String], maxChars: Int = 600) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        var start = trimmed.startIndex
        for token in tokens {
            if let range = trimmed.range(of: token, options: .caseInsensitive) {
                let back = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
                start = trimmed.index(trimmed.startIndex, offsetBy: max(0, back - 150))
                break
            }
        }
        let end = trimmed.index(start, offsetBy: maxChars, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        let body = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > trimmed.startIndex ? "…" : "") + body + (end < trimmed.endIndex ? "…" : "")
    }
}
