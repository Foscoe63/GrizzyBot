import Foundation

public enum MemoryWriteResult: Sendable, Equatable {
    case inserted
    case updated(previous: String)
    case unchanged
    case rejectedSecret
    case empty
}

/// Durable markdown memory: pinned standing rules plus newest facts in the prompt.
public enum MemoryLedger {
    public static let botTitle = "# Memory"
    public static let sharedTitle = "# Shared memory"
    public static let botTemplate = """
    # Memory

    ## Pin

    ## Facts

    """
    public static let sharedTemplate = """
    # Shared memory

    ## Pin

    ## Facts

    """

    public static func template(shared: Bool) -> String {
        shared ? sharedTemplate : botTemplate
    }

    public static func workingSet(_ content: String, maxChars: Int = 1_200) -> String {
        let parsed = parse(content)
        if parsed.pin.isEmpty, parsed.facts.isEmpty {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maxChars else { return trimmed }
            let keep = max(1, maxChars - 48)
            return "…\n\(String(trimmed.suffix(keep)))\n…[truncated — use search_memory]"
        }

        var included: [String] = []
        for fact in parsed.facts.reversed() {
            let trial = render(title: parsed.title, pin: parsed.pin, facts: [fact] + included, truncated: true)
            if trial.count > maxChars, !included.isEmpty { break }
            included.insert(fact, at: 0)
        }
        let truncated = included.count < parsed.facts.count
        var text = render(title: parsed.title, pin: parsed.pin, facts: included, truncated: truncated)
        if text.count > maxChars {
            text = String(text.prefix(max(1, maxChars - 36))) + "\n…[truncated — use search_memory]"
        }
        return text
    }

    public static func upsert(content: String, fact raw: String, title: String = botTitle, pin: Bool = false) -> (text: String, result: MemoryWriteResult) {
        let fact = normalizeFact(raw)
        guard !fact.isEmpty else { return (content, .empty) }
        if looksLikeSecret(fact) { return (content, .rejectedSecret) }

        var parsed = parse(content)
        if parsed.title.isEmpty { parsed.title = title }
        if pin {
            if let idx = parsed.pin.firstIndex(where: { similar($0, fact) }) {
                let previous = parsed.pin[idx]
                if previous == fact { return (compose(parsed), .unchanged) }
                parsed.pin[idx] = fact
                return (compose(parsed), .updated(previous: previous))
            }
            if let idx = parsed.facts.firstIndex(where: { similar($0, fact) }) {
                let previous = parsed.facts.remove(at: idx)
                parsed.pin.append(fact)
                return (compose(parsed), .updated(previous: previous))
            }
            parsed.pin.append(fact)
            return (compose(parsed), .inserted)
        }
        if let idx = parsed.facts.firstIndex(where: { similar($0, fact) }) {
            let previous = parsed.facts[idx]
            if previous == fact { return (compose(parsed), .unchanged) }
            parsed.facts[idx] = fact
            return (compose(parsed), .updated(previous: previous))
        }
        parsed.facts.append(fact)
        return (compose(parsed), .inserted)
    }

    public static func forget(content: String, query: String) -> (text: String, removed: [String]) {
        let tokens = Set(MemoryIndex.tokenize(query))
        guard !tokens.isEmpty else { return (content, []) }
        var parsed = parse(content)
        var removed: [String] = []

        func keep(_ line: String) -> Bool {
            let lineTokens = Set(MemoryIndex.tokenize(line))
            let hit = !tokens.isDisjoint(with: lineTokens)
                && (
                    tokens.isSubset(of: lineTokens)
                        || similar(line, query)
                        || overlap(lineTokens, tokens) >= 0.7
                )
            if hit { removed.append(line) }
            return !hit
        }

        parsed.pin = parsed.pin.filter(keep)
        parsed.facts = parsed.facts.filter(keep)
        return (compose(parsed), removed)
    }

    public static func looksLikeSecret(_ text: String) -> Bool {
        DiagnosticScrubber.redact(text).contains("[redacted]")
    }

    public static func isSparse(_ content: String) -> Bool {
        let parsed = parse(content)
        return parsed.pin.isEmpty && parsed.facts.isEmpty
    }

    // MARK: - Parse / compose

    struct Parsed: Equatable {
        var title: String
        var pin: [String]
        var facts: [String]
    }

    static func parse(_ raw: String) -> Parsed {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var title = ""
        var pin: [String] = []
        var facts: [String] = []
        var section = Section.facts
        var sawPinHeading = false

        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if title.isEmpty, isTitle(line) {
                title = line.hasPrefix("#") ? line : "# \(line)"
                continue
            }
            if isPinHeading(line) {
                section = .pin
                sawPinHeading = true
                continue
            }
            if isFactsHeading(line) {
                section = .facts
                continue
            }
            if isHeading(line) {
                section = .facts
                continue
            }
            if let fact = bullet(line) {
                if section == .pin {
                    pin.append(fact)
                } else {
                    facts.append(fact)
                }
            } else {
                if section == .pin {
                    pin.append(line)
                } else {
                    facts.append(line)
                }
            }
        }
        if !sawPinHeading, pin.isEmpty {
            // Legacy files: every bullet is a fact.
        }
        return Parsed(title: title, pin: pin, facts: facts)
    }

    static func compose(_ parsed: Parsed) -> String {
        render(title: parsed.title, pin: parsed.pin, facts: parsed.facts, truncated: false) + "\n"
    }

    private enum Section { case pin, facts }

    private static func render(title: String, pin: [String], facts: [String], truncated: Bool) -> String {
        var parts: [String] = [title.isEmpty ? botTitle : title]
        if !pin.isEmpty {
            parts.append("## Pin\n" + pin.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !facts.isEmpty {
            parts.append("## Facts\n" + facts.map { "- \($0)" }.joined(separator: "\n"))
        }
        var text = parts.joined(separator: "\n\n")
        if truncated {
            text += "\n\n…[older facts omitted — use search_memory]"
        }
        return text
    }

    static func normalizeFact(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bullet = bullet(text) { text = bullet }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bullet(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "• "] where trimmed.hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        if trimmed == "-" || trimmed == "*" || trimmed == "•" { return nil }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private static func isTitle(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower == "# memory" || lower == "# shared memory" || lower.hasPrefix("# memory") || lower.hasPrefix("# shared")
    }

    private static func isPinHeading(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        return stripped == "pin" || stripped.hasPrefix("pin ")
    }

    private static func isFactsHeading(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        return stripped == "facts" || stripped == "memory"
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let ta = Set(MemoryIndex.tokenize(a))
        let tb = Set(MemoryIndex.tokenize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let inter = Double(ta.intersection(tb).count)
        let union = Double(ta.union(tb).count)
        if union > 0, inter / union >= 0.55 { return true }
        let smaller = Double(min(ta.count, tb.count))
        return smaller >= 2 && inter / smaller >= 0.85
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let smaller = Double(min(a.count, b.count))
        guard smaller > 0 else { return 0 }
        return Double(a.intersection(b).count) / smaller
    }
}

public enum MemoryFiles {
    public static let botFileName = "MEMORY.md"
    public static let sharedFileName = "SHARED.md"

    public static func sharedURL(root: URL) -> URL {
        root.appendingPathComponent(sharedFileName, isDirectory: false)
    }

    public static func read(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func write(_ url: URL, content: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
