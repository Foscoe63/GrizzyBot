import Foundation

/// What the router model has decided lately, and how fast it was. A repeat of the same message to the
/// same set of bots is answered from here instead of waiting for the model again, and the timings tell the
/// person whether the router they picked is fast enough to be worth having.
public struct RoutingMemory: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var botId: String
        public var reason: String
        public var at: Date
    }

    public struct Stats: Sendable, Equatable {
        public var asked = 0
        public var fromCache = 0
        public var failed = 0
        public var totalMs = 0
        public var lastMs: Int?

        public var answered: Int { asked - failed }
        public var averageMs: Int? { answered > 0 ? totalMs / answered : nil }
    }

    public static let ttl: TimeInterval = 10 * 60
    public static let capacity = 100
    /// A deadline in this range is allowed; anything else is clamped.
    public static let timeoutRange: ClosedRange<Double> = 1...30
    public static let defaultTimeout: Double = 6

    public private(set) var entries: [String: Entry] = [:]
    public private(set) var stats = Stats()

    public init() {}

    public static func clampedTimeout(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultTimeout }
        return min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
    }

    /// Same words, same bots, same answer — case and spacing do not matter.
    public static func key(message: String, candidateIds: [String]) -> String {
        let words = message.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return candidateIds.sorted().joined(separator: ",") + "|" + String(words.prefix(600))
    }

    public func lookup(_ key: String, now: Date = .now) -> Entry? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) < Self.ttl else { return nil }
        return entry
    }

    public mutating func recordCacheHit() {
        stats.fromCache += 1
    }

    /// `decision == nil` with `failed == true` is a timeout or error; with `failed == false` the model
    /// answered "nobody in particular", which is a result too but not worth remembering.
    public mutating func record(key: String, decision: RouteDecision?, failed: Bool, milliseconds: Int, now: Date = .now) {
        stats.asked += 1
        if failed {
            stats.failed += 1
            return
        }
        stats.totalMs += milliseconds
        stats.lastMs = milliseconds
        guard let decision else { return }
        entries[key] = Entry(botId: decision.botId, reason: decision.reason, at: now)
        if entries.count > Self.capacity {
            let oldest = entries.sorted { $0.value.at < $1.value.at }.prefix(entries.count - Self.capacity)
            for (k, _) in oldest { entries.removeValue(forKey: k) }
        }
    }

    public mutating func reset() {
        entries = [:]
        stats = Stats()
    }

    public var summary: String {
        guard stats.asked + stats.fromCache > 0 else { return "No messages have needed the router yet." }
        var parts: [String] = []
        if let last = stats.lastMs { parts.append("last \(last) ms") }
        if let avg = stats.averageMs { parts.append("average \(avg) ms") }
        parts.append("\(stats.asked) asked")
        if stats.fromCache > 0 { parts.append("\(stats.fromCache) from memory") }
        if stats.failed > 0 { parts.append("\(stats.failed) timed out or failed") }
        return parts.joined(separator: " · ")
    }
}
