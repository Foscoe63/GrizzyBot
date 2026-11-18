import Foundation

/// Per-fact bookkeeping the markdown memory file cannot hold: when a fact was first seen and last used.
public struct MemoryFactStats: Codable, Sendable, Equatable {
    public var firstSeen: Date
    public var lastUsed: Date?
    public var useCount: Int
    /// Added to the base salience when a fact keeps proving useful.
    public var boost: Double

    public init(firstSeen: Date, lastUsed: Date? = nil, useCount: Int = 0, boost: Double = 0) {
        self.firstSeen = firstSeen
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.boost = boost
    }
}

public struct MemoryConsolidationReport: Sendable, Equatable {
    public var merged: [String] = []
    public var evicted: [String] = []
    public var promoted: [String] = []
    public var changed: Bool { !merged.isEmpty || !evicted.isEmpty || !promoted.isEmpty }
    public init() {}
}

/// Background upkeep for a bot's MEMORY.md: merge near-duplicates, decay salience with age, promote
/// facts that keep being used, and evict what has gone stale. Pins and facts the person marked
/// trusted are never evicted; unverified facts (written after outside content) age out sooner.
public enum MemoryConsolidator {
    public struct Policy: Sendable {
        public var halfLifeDays: Double = 30
        public var evictBelow: Double = 0.1
        public var minIdleDays: Double = 45
        /// An unverified fact needs to have been idle only this long before it can be evicted.
        public var untrustedIdleDays: Double = 14
        public var promoteAtUses: Int = 5
        public var promoteBoost: Double = 0.2
        public var maxFacts: Int = 200
        public var dedupeThreshold: Double = 0.82
        public init() {}
    }

    public static func key(_ fact: String) -> String {
        MemoryLedger.plain(fact).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `salience · exp(-idleDays·ln2 / halfLife)` plus any earned boost.
    public static func decayedSalience(fact: String, stats: MemoryFactStats?, now: Date, policy: Policy = Policy()) -> Double {
        let base = MemorySalience.score(fact) + (stats?.boost ?? 0)
        let anchor = stats?.lastUsed ?? stats?.firstSeen ?? now
        let idleDays = max(0, now.timeIntervalSince(anchor) / 86_400)
        return min(1.0, base) * exp(-idleDays * log(2) / policy.halfLifeDays)
    }

    public static func idleDays(_ stats: MemoryFactStats?, now: Date) -> Double {
        guard let stats else { return 0 }
        return max(0, now.timeIntervalSince(stats.lastUsed ?? stats.firstSeen) / 86_400)
    }

    /// Records that a fact was surfaced to the model.
    public static func touch(_ stats: inout [String: MemoryFactStats], fact: String, now: Date = .now) {
        let k = key(fact)
        var entry = stats[k] ?? MemoryFactStats(firstSeen: now)
        entry.lastUsed = now
        entry.useCount += 1
        stats[k] = entry
    }

    public static func consolidate(
        content: String,
        stats: [String: MemoryFactStats],
        now: Date = .now,
        policy: Policy = Policy()
    ) -> (content: String, stats: [String: MemoryFactStats], report: MemoryConsolidationReport) {
        var report = MemoryConsolidationReport()
        var stats = stats
        var parsed = MemoryLedger.parse(content)

        // Facts seen for the first time start their clock now.
        for fact in parsed.facts + parsed.pin where stats[key(fact)] == nil {
            stats[key(fact)] = MemoryFactStats(firstSeen: now)
        }

        // 1. Merge near-duplicates, keeping the best-scored copy and carrying its usage forward.
        let clusters = MemoryFactDedupe.clusters(from: parsed.facts, threshold: policy.dedupeThreshold)
        if !clusters.isEmpty {
            let drop = Set(clusters.flatMap(\.duplicates))
            for cluster in clusters {
                var keep = stats[key(cluster.keep)] ?? MemoryFactStats(firstSeen: now)
                for dup in cluster.duplicates {
                    if let other = stats[key(dup)] {
                        keep.useCount += other.useCount
                        keep.firstSeen = min(keep.firstSeen, other.firstSeen)
                        if let used = other.lastUsed, used > (keep.lastUsed ?? .distantPast) { keep.lastUsed = used }
                    }
                }
                stats[key(cluster.keep)] = keep
            }
            parsed.facts.removeAll { fact in
                guard drop.contains(fact) else { return false }
                report.merged.append(fact)
                stats[key(fact)] = nil
                return true
            }
        }

        // 2. Promote facts that keep proving useful.
        for fact in parsed.facts {
            guard var entry = stats[key(fact)], entry.useCount >= policy.promoteAtUses, entry.boost == 0 else { continue }
            entry.boost = policy.promoteBoost
            stats[key(fact)] = entry
            report.promoted.append(fact)
        }

        // 3. Evict what has decayed away, then enforce the size cap.
        func evictable(_ fact: String) -> Bool {
            let entry = stats[key(fact)]
            let idle = idleDays(entry, now: now)
            let need = MemoryLedger.isUntrusted(fact) ? policy.untrustedIdleDays : policy.minIdleDays
            return idle >= need && decayedSalience(fact: fact, stats: entry, now: now, policy: policy) < policy.evictBelow
        }
        parsed.facts.removeAll { fact in
            guard evictable(fact) else { return false }
            report.evicted.append(fact)
            stats[key(fact)] = nil
            return true
        }
        if parsed.facts.count > policy.maxFacts {
            let ranked = parsed.facts.sorted {
                decayedSalience(fact: $0, stats: stats[key($0)], now: now, policy: policy)
                    < decayedSalience(fact: $1, stats: stats[key($1)], now: now, policy: policy)
            }
            let overflow = Set(ranked.prefix(parsed.facts.count - policy.maxFacts))
            parsed.facts.removeAll { fact in
                guard overflow.contains(fact) else { return false }
                report.evicted.append(fact)
                stats[key(fact)] = nil
                return true
            }
        }

        // Forget stats for facts that no longer exist.
        let live = Set((parsed.facts + parsed.pin).map(key))
        stats = stats.filter { live.contains($0.key) }

        return (report.changed ? MemoryLedger.compose(parsed) : content, stats, report)
    }
}
