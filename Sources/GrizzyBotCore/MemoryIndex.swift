import Foundation

public struct MemoryHit: Sendable, Equatable {
    public var path: String
    public var scope: String
    public var snippet: String
    public var score: Int

    public init(path: String, scope: String, snippet: String, score: Int) {
        self.path = path
        self.scope = scope
        self.snippet = snippet
        self.score = score
    }
}

/// Keyword retrieval over bot + shared memory. The prompt only gets an excerpt;
/// agents call `search_memory` for the rest.
public enum MemoryIndex {
    public static func excerpt(_ content: String, maxChars: Int = 1_200) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let head = String(trimmed.prefix(maxChars))
        return head + "\n…[truncated \(trimmed.count - maxChars) chars — use search_memory]"
    }

    public static func search(
        documents: [MemoryDocument],
        query: String,
        limit: Int = 8
    ) -> [MemoryHit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [MemoryHit] = []
        for doc in documents {
            let lines = doc.content.split(whereSeparator: \.isNewline).map(String.init)
            for line in lines {
                let lowered = line.lowercased()
                let score = tokens.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
                guard score > 0 else { continue }
                let snippet = line.trimmingCharacters(in: .whitespaces)
                guard !snippet.isEmpty, snippet != "# Memory", snippet != "# Shared memory" else { continue }
                hits.append(
                    MemoryHit(
                        path: doc.path,
                        scope: doc.scope,
                        snippet: String(snippet.prefix(280)),
                        score: score
                    )
                )
            }
        }
        return Array(
            hits.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
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
