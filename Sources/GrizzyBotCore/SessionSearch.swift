import Foundation

/// Keyword search over a bot's own past conversations, so it can find what was said weeks ago
/// without that history being stuffed into every prompt.
public enum SessionSearch {
    public struct Doc: Sendable, Equatable {
        public var thread: String
        public var role: MessageRole
        public var date: Date
        public var text: String

        public init(thread: String, role: MessageRole, date: Date, text: String) {
            self.thread = thread
            self.role = role
            self.date = date
            self.text = text
        }
    }

    public struct Hit: Sendable, Equatable {
        public var thread: String
        public var role: MessageRole
        public var date: Date
        public var snippet: String
        public var score: Double
    }

    public static func search(docs: [Doc], query: String, limit: Int = 8, now: Date = .now) -> [Hit] {
        let terms = MemoryIndex.tokenize(query)
        guard !terms.isEmpty, !docs.isEmpty else { return [] }
        let tokenized = docs.map { MemoryIndex.tokenize($0.text) }

        var df: [String: Int] = [:]
        for tokens in tokenized {
            for term in Set(tokens) { df[term, default: 0] += 1 }
        }
        let n = Double(docs.count)
        let avgdl = max(1, tokenized.map { Double($0.count) }.reduce(0, +) / n)
        let k1 = 1.5, b = 0.75

        var hits: [Hit] = []
        for (doc, tokens) in zip(docs, tokenized) {
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            var score = 0.0
            for term in terms {
                let f = Double(tf[term] ?? 0)
                guard f > 0 else { continue }
                let d = Double(df[term] ?? 0)
                let idf = log((n - d + 0.5) / (d + 0.5) + 1)
                let dl = Double(max(1, tokens.count))
                score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
            }
            guard score > 0 else { continue }
            let age = max(0, now.timeIntervalSince(doc.date))
            score *= 0.85 + 0.15 / (1 + age / (86_400 * 30))
            hits.append(Hit(thread: doc.thread, role: doc.role, date: doc.date, snippet: snippet(doc.text, terms: terms), score: score))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }.prefix(limit))
    }

    /// About 280 characters centred on the first query word found.
    static func snippet(_ text: String, terms: [String], width: Int = 280) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > width else { return flat }
        let lower = flat.lowercased()
        var center = 0
        for term in terms {
            if let r = lower.range(of: term) {
                center = lower.distance(from: lower.startIndex, to: r.lowerBound)
                break
            }
        }
        let start = max(0, center - width / 3)
        let from = flat.index(flat.startIndex, offsetBy: start)
        let to = flat.index(from, offsetBy: min(width, flat.count - start))
        return (start > 0 ? "…" : "") + String(flat[from..<to]) + (to < flat.endIndex ? "…" : "")
    }

    public static func render(_ hits: [Hit]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return hits.map { hit in
            let who = hit.role == .user ? "person" : "you"
            return "• [\(formatter.string(from: hit.date)) · \(who) · \(hit.thread)] \(hit.snippet)"
        }.joined(separator: "\n")
    }
}
