import Foundation
import NaturalLanguage

/// A text vector, comparable by cosine.
public struct MemoryVector: Sendable, Equatable {
    public let values: [Double]

    public init(_ values: [Double]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    /// 1 for identical direction, 0 for orthogonal or degenerate input.
    public static func cosine(_ a: MemoryVector, _ b: MemoryVector) -> Double {
        guard a.values.count == b.values.count, !a.values.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for (x, y) in zip(a.values, b.values) {
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}

/// Sentence vectors for memory retrieval, cached by the text they came from.
///
/// `NaturalLanguage` rather than a downloaded model: it ships with the OS, needs
/// no network and no MLX, and runs synchronously — which matters because
/// `MemoryLean.search` is called from synchronous prompt assembly and making it
/// async would ripple through every caller.
///
/// The embedding is optional on purpose. `sentenceEmbedding(for:)` returns nil
/// when the assets are missing, and callers fall back to keyword-only retrieval
/// rather than losing memory entirely.
public final class MemoryEmbedder: @unchecked Sendable {
    public static let shared = MemoryEmbedder()

    /// For tests and for the fallback path: an embedder that can never answer.
    public static let unavailable = MemoryEmbedder(source: nil)

    /// Resolved once — building an NLEmbedding is expensive enough that doing it
    /// per instance would show up in prompt assembly.
    ///
    /// `nonisolated(unsafe)` because NLEmbedding is not Sendable and Apple
    /// documents no thread-safety guarantee for it. The unsafety is made safe by
    /// `embeddingLock`: every call into an NLEmbedding, this one or an injected
    /// one, is serialised through it. Coarse, but embedding is not on a hot
    /// parallel path — a memory search embeds a few hundred short chunks once
    /// and reads the cache thereafter.
    nonisolated(unsafe) private static let englishSentences: NLEmbedding? =
        NLEmbedding.sentenceEmbedding(for: .english)

    private static let embeddingLock = NSLock()

    private let source: NLEmbedding?
    private let cacheLimit: Int
    private let lock = NSLock()
    private var cache: [String: MemoryVector] = [:]
    private var insertionOrder: [String] = []

    public init(source: NLEmbedding?, cacheLimit: Int = 1_024) {
        self.source = source
        self.cacheLimit = max(1, cacheLimit)
    }

    public convenience init() {
        self.init(source: MemoryEmbedder.englishSentences)
    }

    /// The OS embedding with a chosen cache size.
    public convenience init(cacheLimit: Int) {
        self.init(source: MemoryEmbedder.englishSentences, cacheLimit: cacheLimit)
    }

    public var isAvailable: Bool { source != nil }

    public var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// The vector for `text`, or nil when there is no embedding to be had.
    ///
    /// Long chunks are truncated: sentence embeddings are meant for a sentence,
    /// and the tail of a 900-character chunk contributes noise rather than
    /// meaning.
    public func vector(for text: String) -> MemoryVector? {
        guard let source else { return nil }
        let key = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !key.isEmpty else { return nil }

        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        Self.embeddingLock.lock()
        let raw = source.vector(for: key)
        Self.embeddingLock.unlock()
        guard let raw, !raw.isEmpty else { return nil }
        let vector = MemoryVector(raw)

        lock.lock()
        if cache[key] == nil {
            cache[key] = vector
            insertionOrder.append(key)
            // Oldest-first eviction. A memory search walks the same chunks over
            // and over, so anything smarter would not earn its complexity.
            while insertionOrder.count > cacheLimit {
                cache.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        lock.unlock()
        return vector
    }
}

/// Semantic retrieval over the same chunks BM25 sees.
///
/// This is a retrieval lane, not a re-ranker: it scores every chunk in scope, so
/// a passage that shares no keyword with the query can still surface. That is
/// the whole point — re-ranking what BM25 already found cannot add recall, which
/// is the limitation of the salience lane this sits beside.
public enum MemorySemanticIndex {
    /// Chunks embedded for a single query. Bounds the cost of a first, cold
    /// search over a large memory; BM25 still sees everything.
    public static let maxChunks = 400

    public static func rank(
        documents: [MemoryDocument],
        query: String,
        limit: Int = 8,
        botId: String? = nil,
        embedder: MemoryEmbedder = .shared
    ) -> [MemoryHit] {
        guard embedder.isAvailable,
              let queryVector = embedder.vector(for: query)
        else { return [] }

        let scoped = MemoryIndex.scopedDocuments(documents, botId: botId)
        let chunks = scoped.flatMap(MemoryIndex.chunk).prefix(maxChunks)
        guard !chunks.isEmpty else { return [] }

        var hits: [MemoryHit] = []
        for chunk in chunks {
            guard let vector = embedder.vector(for: chunk.text) else { continue }
            let score = MemoryVector.cosine(queryVector, vector)
            // Everything correlates a little; a floor keeps the lane from
            // ranking the whole of memory on noise.
            guard score > 0.2 else { continue }
            hits.append(
                MemoryHit(
                    path: chunk.document.path,
                    scope: chunk.document.scope,
                    snippet: String(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280)),
                    score: score
                )
            )
        }

        return Array(
            hits.sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
                return lhs.snippet < rhs.snippet
            }
            .prefix(max(1, limit))
        )
    }
}
