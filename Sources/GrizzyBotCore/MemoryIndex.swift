import Foundation

public struct MemoryHit: Sendable, Equatable {
    public var path: String
    public var scope: String
    public var snippet: String
    public var score: Double

    public init(path: String, scope: String, snippet: String, score: Double) {
        self.path = path
        self.scope = scope
        self.snippet = snippet
        self.score = score
    }
}

struct MemoryChunk: Sendable {
    var document: MemoryDocument
    var text: String
    var tokens: [String]
}

/// Keyword retrieval over bot + shared memory. The prompt only gets an excerpt;
/// agents call `search_memory` for the rest.
public enum MemoryIndex {
    public static func excerpt(_ content: String, maxChars: Int = 1_200) -> String {
        MemoryLedger.workingSet(content, maxChars: maxChars)
    }

    public static func scopedDocuments(_ documents: [MemoryDocument], botId: String?) -> [MemoryDocument] {
        guard let botId, !botId.isEmpty else { return documents }
        return documents.filter { doc in
            if doc.scope == "workspace" || doc.path == "SHARED.md" { return true }
            return doc.botId == botId
        }
    }

    public static func search(
        documents: [MemoryDocument],
        query: String,
        limit: Int = 8,
        botId: String? = nil,
        now: Date = .now
    ) -> [MemoryHit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        let scoped = scopedDocuments(documents, botId: botId)
        let chunks = scoped.flatMap(chunk)
        guard !chunks.isEmpty else { return [] }

        var df: [String: Int] = [:]
        for chunk in chunks {
            for term in Set(chunk.tokens) {
                df[term, default: 0] += 1
            }
        }
        let avgdl = chunks.map { Double($0.tokens.count) }.reduce(0, +) / Double(max(1, chunks.count))
        let n = Double(chunks.count)
        let k1 = 1.5
        let b = 0.75

        var hits: [MemoryHit] = []
        for chunk in chunks {
            var bm25 = 0.0
            var tf: [String: Int] = [:]
            for term in chunk.tokens { tf[term, default: 0] += 1 }
            for term in tokens {
                let freq = Double(tf[term] ?? 0)
                guard freq > 0 else { continue }
                let docsWith = Double(df[term] ?? 0)
                let idf = log((n - docsWith + 0.5) / (docsWith + 0.5) + 1)
                let dl = Double(max(1, chunk.tokens.count))
                let denom = freq + k1 * (1 - b + b * dl / max(avgdl, 1))
                bm25 += idf * (freq * (k1 + 1)) / denom
            }
            guard bm25 > 0 else { continue }
            let age = max(0, now.timeIntervalSince(chunk.document.updatedAt))
            let recency = 1.0 / (1.0 + age / (60 * 60 * 24 * 30))
            let score = bm25 * (0.85 + 0.15 * recency)
            let snippet = String(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
            guard !snippet.isEmpty, snippet != "# Memory", snippet != "# Shared memory" else { continue }
            hits.append(
                MemoryHit(
                    path: chunk.document.path,
                    scope: chunk.document.scope,
                    snippet: snippet,
                    score: score
                )
            )
        }
        return Array(
            hits.sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
                return lhs.snippet < rhs.snippet
            }
            .prefix(limit)
        )
    }

    public static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    static func chunk(_ document: MemoryDocument) -> [MemoryChunk] {
        let paragraphs = document.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pieces: [String]
        if paragraphs.count <= 1 {
            pieces = slidingLines(document.content)
        } else {
            pieces = paragraphs.flatMap { paragraph -> [String] in
                if paragraph.count > 900 { return slidingLines(paragraph) }
                return [paragraph]
            }
        }
        return pieces.map { text in
            MemoryChunk(document: document, text: text, tokens: tokenize(text))
        }
        .filter { !$0.tokens.isEmpty }
    }

    private static func slidingLines(_ text: String, window: Int = 4, overlap: Int = 1) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "#" && $0 != "# Memory" && $0 != "# Shared memory" }
        guard !lines.isEmpty else { return [] }
        if lines.count <= window { return [lines.joined(separator: "\n")] }
        var out: [String] = []
        var start = 0
        while start < lines.count {
            let end = min(lines.count, start + window)
            out.append(lines[start..<end].joined(separator: "\n"))
            if end == lines.count { break }
            start += max(1, window - overlap)
        }
        return out
    }
}

/// Line-oriented unified diff for file writes shown to the user and the model.
public enum TextDiff {
    public static func unified(before: String, after: String, path: String) -> String {
        let oldLines = splitLines(before)
        let newLines = splitLines(after)
        if oldLines == newLines {
            return "--- \(path)\n+++ \(path)\n(no changes)"
        }
        var start = 0
        let shared = min(oldLines.count, newLines.count)
        while start < shared, oldLines[start] == newLines[start] { start += 1 }
        var endOld = oldLines.count
        var endNew = newLines.count
        while endOld > start, endNew > start, oldLines[endOld - 1] == newLines[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        var lines = ["--- \(path)", "+++ \(path)"]
        if before.isEmpty { lines.append("@@ new file @@") }
        else { lines.append("@@ hunk @@") }
        if start < endOld {
            for i in start..<endOld { lines.append("- \(oldLines[i])") }
        }
        if start < endNew {
            for i in start..<endNew { lines.append("+ \(newLines[i])") }
        }
        let body = lines.joined(separator: "\n")
        if body.count > 4_000 {
            return String(body.prefix(3_700)) + "\n…[diff truncated]"
        }
        return body
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}
