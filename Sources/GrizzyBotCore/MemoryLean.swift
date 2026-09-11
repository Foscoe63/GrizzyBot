import Foundation

/// Which memory slice to inject for this turn (Osaurus-style lean gate).
public enum MemoryRecallSection: String, Sendable, Equatable {
    case none
    case identity
    case pinned
    case episode
}

public enum MemoryRelevanceGateMode: String, Codable, Sendable {
    /// Always inject Pin + newest Facts (legacy GrizzyBot).
    case always
    /// Skip Facts unless the query looks memory-relevant; Pin always when present.
    case heuristic
    case off
}

public enum MemoryRelevanceGate {
    public static func decide(
        query: String,
        mode: MemoryRelevanceGateMode = .heuristic
    ) -> MemoryRecallSection {
        if mode == .off { return .none }
        if mode == .always { return .episode }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .none }
        let lower = trimmed.lowercased()

        let identityPhrases = [
            "what's my name", "what is my name", "who am i", "tell me about myself",
            "what do you know about me", "what do you remember about me",
            "where do i work", "what's my job", "what's my role",
        ]
        if identityPhrases.contains(where: { lower.contains($0) }) {
            return .identity
        }
        if hasTemporalMarker(lower) || hasPriorContextPronoun(lower) {
            return .episode
        }
        if hasExplicitRecallVerb(lower) || isPossessiveReference(lower) {
            return .pinned
        }
        return .none
    }

    private static func hasTemporalMarker(_ s: String) -> Bool {
        let needles = [
            "yesterday", "last week", "last time", "last session", "earlier",
            "previously", "before", "ago", "when did",
        ]
        return needles.contains(where: { s.contains($0) })
    }

    private static func hasPriorContextPronoun(_ s: String) -> Bool {
        let needles = ["that", "this", "it again", "as before", "same as", "like last"]
        return needles.contains(where: { s.contains($0) })
            && (s.contains("remember") || s.contains("said") || s.contains("told") || s.contains("we "))
    }

    private static func hasExplicitRecallVerb(_ s: String) -> Bool {
        ["remember", "recall", "you know", "didn't i", "did i tell", "i told you"]
            .contains(where: { s.contains($0) })
    }

    private static func isPossessiveReference(_ s: String) -> Bool {
        ["my ", "our "].contains(where: { s.contains($0) })
            && ["preference", "rule", "always", "never", "project", "repo", "email"]
            .contains(where: { s.contains($0) })
    }
}

/// Rule-based salience for Facts (higher = keep longer).
public enum MemorySalience {
    public static func score(_ fact: String) -> Double {
        let lower = fact.lowercased()
        var score = 0.35
        if lower.contains("always") || lower.contains("never") || lower.contains("must") {
            score += 0.25
        }
        if lower.contains("prefer") || lower.contains("rule") || lower.contains("policy") {
            score += 0.15
        }
        if lower.contains("@") || lower.contains("http") {
            score += 0.05
        }
        if fact.count > 160 { score -= 0.05 }
        if fact.count < 24 { score -= 0.05 }
        return min(1.0, max(0.05, score))
    }
}

public struct MemoryFactCluster: Sendable, Equatable, Identifiable {
    public var keep: String
    public var duplicates: [String]
    public var similarity: Double

    public var id: String { keep }

    public init(keep: String, duplicates: [String], similarity: Double) {
        self.keep = keep
        self.duplicates = duplicates
        self.similarity = similarity
    }
}

/// Jaccard near-dup clusters over MEMORY.md Facts (and optional Pin).
public enum MemoryFactDedupe {
    public static func clusters(from facts: [String], threshold: Double = 0.82) -> [MemoryFactCluster] {
        let sorted = facts.sorted { MemorySalience.score($0) > MemorySalience.score($1) }
        var used = Set<Int>()
        var out: [MemoryFactCluster] = []
        for i in sorted.indices {
            if used.contains(i) { continue }
            var dups: [String] = []
            var best = 0.0
            for j in sorted.indices where j != i && !used.contains(j) {
                let sim = jaccard(sorted[i], sorted[j])
                if sim >= threshold {
                    dups.append(sorted[j])
                    used.insert(j)
                    best = max(best, sim)
                }
            }
            guard !dups.isEmpty else { continue }
            used.insert(i)
            out.append(MemoryFactCluster(keep: sorted[i], duplicates: dups, similarity: best))
        }
        return out
    }

    /// Drop duplicate Facts from markdown content; keep the highest-salience copy.
    public static func mergeContent(_ content: String, threshold: Double = 0.82) -> (text: String, removed: [String]) {
        let parsed = MemoryLedger.parse(content)
        let clusters = clusters(from: parsed.facts, threshold: threshold)
        guard !clusters.isEmpty else { return (content, []) }
        let drop = Set(clusters.flatMap(\.duplicates))
        var removed: [String] = []
        var next = parsed
        next.facts = parsed.facts.filter { fact in
            if drop.contains(fact) {
                removed.append(fact)
                return false
            }
            return true
        }
        return (MemoryLedger.compose(next), removed)
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        let left = Set(MemoryIndex.tokenize(a))
        let right = Set(MemoryIndex.tokenize(b))
        if left.isEmpty, right.isEmpty { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }
        let inter = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(inter) / Double(union)
    }
}

/// Reciprocal rank fusion (GrizzyClaw / Osaurus hybrid search).
public enum MemoryHybridSearch {
    public static let defaultK = 60

    public static func reciprocalRankFusion(
        textIDs: [String],
        vectorIDs: [String],
        limit: Int,
        k: Int = defaultK
    ) -> [String] {
        var scores: [String: Double] = [:]
        for (rank, id) in textIDs.enumerated() {
            scores[id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        for (rank, id) in vectorIDs.enumerated() {
            scores[id, default: 0] += 1.0 / Double(k + rank + 1)
        }
        return scores
            .sorted { lhs, rhs in
                if abs(lhs.value - rhs.value) > 0.000_001 { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(max(1, limit))
            .map(\.key)
    }

    /// Quote tokens so FTS MATCH punctuation doesn't break (when SQLite FTS is added).
    public static func ftsQuery(from raw: String) -> String {
        MemoryIndex.tokenize(raw)
            .map { "\"\($0)\"" }
            .joined(separator: " ")
    }

    /// Hybrid-ish: BM25 primary + secondary ranking by salience/overlap RRF for snippet ids.
    public static func search(
        documents: [MemoryDocument],
        query: String,
        limit: Int = 8,
        botId: String? = nil
    ) -> [MemoryHit] {
        let textHits = MemoryIndex.search(documents: documents, query: query, limit: limit * 2, botId: botId)
        guard !textHits.isEmpty else { return [] }
        // Second lane: same hits re-ranked by salience of snippet (stand-in until embeddings land).
        let salienceSorted = textHits.sorted {
            MemorySalience.score($0.snippet) > MemorySalience.score($1.snippet)
        }
        let textIDs = textHits.map { "\($0.path)#\($0.snippet.prefix(48))" }
        let vectorIDs = salienceSorted.map { "\($0.path)#\($0.snippet.prefix(48))" }
        let fused = reciprocalRankFusion(textIDs: textIDs, vectorIDs: vectorIDs, limit: limit)
        let byId = Dictionary(uniqueKeysWithValues: zip(textIDs, textHits))
        return fused.compactMap { byId[$0] }
    }
}

/// Build lean memory text for the system prompt.
public enum MemoryLeanInject {
    public static func excerpt(
        content: String,
        query: String,
        mode: MemoryRelevanceGateMode,
        maxChars: Int = 1_200
    ) -> String {
        let section = MemoryRelevanceGate.decide(query: query, mode: mode)
        let parsed = MemoryLedger.parse(content)
        switch section {
        case .none:
            if parsed.pin.isEmpty { return "" }
            return MemoryLedger.render(title: parsed.title, pin: parsed.pin, facts: [], truncated: false)
        case .identity, .pinned:
            let facts = Array(parsed.facts.suffix(2))
            return MemoryLedger.workingSet(
                MemoryLedger.render(title: parsed.title, pin: parsed.pin, facts: facts, truncated: parsed.facts.count > 2),
                maxChars: maxChars
            )
        case .episode:
            return MemoryIndex.excerpt(content, maxChars: maxChars)
        }
    }
}
