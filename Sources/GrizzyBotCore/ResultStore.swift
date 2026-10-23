import Foundation

/// Full tool outputs for one agent run. The model sees a compressed view in its transcript and can
/// pull the rest back with `recall_result`, so compression never loses anything for good.
public final class ResultStore: @unchecked Sendable {
    struct Entry {
        let id: String
        let tool: String
        let lines: [String]
        let chars: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var counter = 0
    private var totalChars = 0
    private let maxEntries: Int
    private let maxTotalChars: Int

    public init(maxEntries: Int = 64, maxTotalChars: Int = 12_000_000) {
        self.maxEntries = maxEntries
        self.maxTotalChars = maxTotalChars
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Stores `text` (JSON is pretty-printed so line reads and search work) and returns its id.
    @discardableResult
    public func put(tool: String, text: String) -> String {
        let stored = ToolOutputCompressor.prettyIfJSON(text)
        let lines = stored.components(separatedBy: "\n")
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let id = "r\(counter)"
        entries[id] = Entry(id: id, tool: tool, lines: lines, chars: stored.count)
        order.append(id)
        totalChars += stored.count
        while order.count > 1, order.count > maxEntries || totalChars > maxTotalChars {
            let oldest = order.removeFirst()
            if let gone = entries.removeValue(forKey: oldest) { totalChars -= gone.chars }
        }
        return id
    }

    func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if let gone = entries.removeValue(forKey: id) { totalChars -= gone.chars }
        order.removeAll { $0 == id }
    }

    func entry(_ id: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    private func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { entries[$0] }
    }

    /// Compresses `raw` when it is large, keeping the original retrievable. Nil means "send as is".
    public func stash(tool: String, raw: String) -> String? {
        guard raw.count > ToolOutputCompressor.threshold else { return nil }
        let id = put(tool: tool, text: raw)
        guard let entry = entry(id),
              let compressed = ToolOutputCompressor.compress(
                  raw, tool: tool, id: id, lineCount: entry.lines.count, charCount: entry.chars
              )
        else {
            remove(id)
            return nil
        }
        return compressed
    }

    // MARK: recall_result

    static let readCap = 12_000
    static let searchCap = 8_000

    /// Serves a `recall_result` call: search with `query`, or read a range with `line`/`lines`.
    public func recall(arguments: String) -> String {
        let args = Self.parse(arguments)
        let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let all = snapshot()
        guard !all.isEmpty else {
            return "Nothing is stored. Full outputs are only kept for the current job; re-run the tool if you need the data."
        }
        let available = all.map { "\($0.id) (\($0.tool), \($0.lines.count) lines)" }.joined(separator: ", ")
        var targets = all
        if !id.isEmpty {
            guard let match = all.first(where: { $0.id == id }) else {
                return "No stored output \(id). Available: \(available)"
            }
            targets = [match]
        }
        if !query.isEmpty {
            let limit = min(max(Self.intArg(args["limit"]) ?? 5, 1), 10)
            return Self.search(targets, query: query, limit: limit)
        }
        guard targets.count == 1, let entry = targets.first else {
            return "Pass id (and optionally line/lines) or a query. Available: \(available)"
        }
        let start = max(1, Self.intArg(args["line"]) ?? 1)
        let wanted = min(max(Self.intArg(args["lines"]) ?? 200, 1), 400)
        return Self.read(entry, start: start, count: wanted)
    }

    static func read(_ entry: Entry, start: Int, count: Int) -> String {
        let total = entry.lines.count
        guard start <= total else { return "\(entry.id) has only \(total) lines." }
        var out: [String] = []
        var used = 0
        var index = start - 1
        let stop = min(total, index + count)
        while index < stop {
            let line = entry.lines[index]
            if used + line.count > readCap, !out.isEmpty { break }
            out.append(line.count > readCap ? String(line.prefix(readCap)) + "…" : line)
            used += line.count + 1
            index += 1
        }
        var text = "[\(entry.id) lines \(start)-\(index) of \(total)]\n" + out.joined(separator: "\n")
        if index < total {
            text += "\n[more: recall_result(id:\"\(entry.id)\", line:\(index + 1))]"
        }
        return text
    }

    static func search(_ targets: [Entry], query: String, limit: Int) -> String {
        var terms = query.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
            .filter { $0.count >= 2 }
        if terms.isEmpty { terms = [query.lowercased()] }
        struct Hit { let id: String; let start: Int; let end: Int; let score: Double; let lines: [String] }
        var hits: [Hit] = []
        for entry in targets {
            let lowered = entry.lines.map { $0.lowercased() }
            let n = Double(max(lowered.count, 1))
            var weights: [Double] = []
            for term in terms {
                let df = Double(lowered.reduce(0) { $0 + ($1.contains(term) ? 1 : 0) })
                weights.append(df == 0 ? 0 : log(1 + n / df))
            }
            var scores = [Double](repeating: 0, count: lowered.count)
            for (i, line) in lowered.enumerated() {
                for (t, term) in terms.enumerated() where weights[t] > 0 && line.contains(term) {
                    scores[i] += weights[t]
                }
            }
            let best = scores.indices.filter { scores[$0] > 0 }
                .sorted { scores[$0] > scores[$1] }
                .prefix(limit * 3)
            var ranges: [(Int, Int)] = best
                .map { (max(0, $0 - 2), min(lowered.count - 1, $0 + 2)) }
                .sorted { $0.0 < $1.0 }
            var merged: [(Int, Int)] = []
            for range in ranges {
                if let last = merged.last, range.0 <= last.1 + 1 {
                    merged[merged.count - 1].1 = max(last.1, range.1)
                } else {
                    merged.append(range)
                }
            }
            ranges = merged
            for (lo, hi) in ranges {
                let capped = min(hi, lo + 19)
                let score = (lo...capped).reduce(0.0) { $0 + scores[$1] }
                hits.append(Hit(id: entry.id, start: lo, end: capped, score: score, lines: Array(entry.lines[lo...capped])))
            }
        }
        guard !hits.isEmpty else {
            return "No match for \"\(query)\" in " + targets.map(\.id).joined(separator: ", ") + "."
        }
        let top = hits.sorted { $0.score > $1.score }.prefix(limit)
            .sorted { ($0.id, $0.start) < ($1.id, $1.start) }
        var out = ""
        for hit in top {
            let block = "[\(hit.id) lines \(hit.start + 1)-\(hit.end + 1)]\n"
                + hit.lines.map { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 }.joined(separator: "\n")
                + "\n"
            if out.count + block.count > searchCap, !out.isEmpty { break }
            out += block
        }
        return out + "[read more with recall_result(id, line, lines)]"
    }

    static func parse(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func intArg(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Shrinks a large tool output by what it is (JSON, code, log, prose) instead of cutting the middle out.
public enum ToolOutputCompressor {
    public static let threshold = 3_500

    public enum Kind: String, Sendable {
        case json, code, log, text
    }

    private static let signaturePrefixes = [
        "func ", "class ", "struct ", "enum ", "protocol ", "extension ", "actor ", "def ", "function ",
        "export ", "interface ", "impl ", "fn ", "pub ", "public ", "private ", "internal ", "static ",
        "import ", "#include", "// MARK", "@",
    ]
    private static let notableWords = [
        "error", "fatal", "exception", "panic", "fail", "traceback", "denied", "timeout", "timed out", "warn",
    ]
    private static let levelWords = [" error", " warn", " info", " debug", " fatal", "[error", "[warn", "[info"]

    static func parseJSON(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func prettyIfJSON(_ text: String) -> String {
        guard text.count > threshold, !text.contains("\n") || text.split(separator: "\n").count <= 3,
              let object = parseJSON(text),
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let pretty = String(data: data, encoding: .utf8)
        else { return text }
        return pretty
    }

    public static func detect(_ raw: String, tool: String) -> Kind {
        if parseJSON(raw) != nil { return .json }
        let lines = raw.components(separatedBy: "\n")
        let signatures = lines.reduce(0) { count, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return count + (signaturePrefixes.contains { t.hasPrefix($0) } ? 1 : 0)
        }
        if tool == "read_file" || (lines.count >= 20 && signatures * 20 >= lines.count) { return .code }
        if lines.count >= 30 {
            let leveled = lines.reduce(0) { count, line in
                let lower = line.lowercased()
                return count + (levelWords.contains { lower.contains($0) } ? 1 : 0)
            }
            if leveled * 5 >= lines.count { return .log }
        }
        return .text
    }

    public static func compress(
        _ raw: String, tool: String, id: String, lineCount: Int, charCount: Int
    ) -> String? {
        let kind = detect(raw, tool: tool)
        let body: String
        switch kind {
        case .json: body = jsonSummary(raw)
        case .code: body = codeSummary(raw)
        case .log: body = logSummary(raw)
        case .text: body = ContextCompactor.summarizePayload(raw, head: 2_000, tail: 1_000)
        }
        let footer = "\n[stored as \(id): \(lineCount) lines / \(charCount) chars, \(kind.rawValue) summary shown. "
            + "recall_result(id:\"\(id)\", query:\"…\") searches it; recall_result(id:\"\(id)\", line:N, lines:M) reads more.]"
        let result = body + footer
        return result.count < raw.count ? result : nil
    }

    // MARK: summaries

    static func jsonSummary(_ raw: String) -> String {
        guard let object = parseJSON(raw) else { return ContextCompactor.summarizePayload(raw) }
        let shrunk = shrink(object, depth: 0)
        guard JSONSerialization.isValidJSONObject(shrunk),
              let data = try? JSONSerialization.data(
                  withJSONObject: shrunk, options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return ContextCompactor.summarizePayload(raw) }
        return text.count > 6_000 ? ContextCompactor.summarizePayload(text, head: 3_500, tail: 1_500) : text
    }

    private static func shrink(_ value: Any, depth: Int) -> Any {
        if let dict = value as? [String: Any] {
            if depth >= 6 { return "{…\(dict.count) keys}" }
            let keys = dict.keys.sorted()
            var out: [String: Any] = [:]
            for key in keys.prefix(40) { out[key] = shrink(dict[key] as Any, depth: depth + 1) }
            if keys.count > 40 { out["_omitted_keys"] = keys.count - 40 }
            return out
        }
        if let array = value as? [Any] {
            if depth >= 6 { return "[…\(array.count) items]" }
            var out = array.prefix(3).map { shrink($0, depth: depth + 1) }
            if array.count > 3 { out.append("…\(array.count - 3) more items (total \(array.count))") }
            return out
        }
        if let string = value as? String, string.count > 300 {
            return String(string.prefix(200)) + "…(+\(string.count - 200) chars)"
        }
        return value
    }

    static func codeSummary(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        let head = 15, tail = 5
        var out: [String] = []
        for i in 0..<min(head, lines.count) { out.append(clip("L\(i + 1): \(lines[i])")) }
        var skipped = 0
        if lines.count > head + tail {
            var signatures = 0
            for i in head..<(lines.count - tail) {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard signaturePrefixes.contains(where: { t.hasPrefix($0) }) else { continue }
                if signatures < 80 {
                    out.append(clip("L\(i + 1): \(t)"))
                    signatures += 1
                } else {
                    skipped += 1
                }
            }
            out.append("…[\(lines.count - head - tail) lines between, only declarations shown]…")
            if skipped > 0 { out.append("…[\(skipped) more declarations]…") }
        }
        let tailStart = min(lines.count, max(head, lines.count - tail))
        for i in tailStart..<lines.count { out.append(clip("L\(i + 1): \(lines[i])")) }
        return out.joined(separator: "\n")
    }

    static func logSummary(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        let head = 8, tail = 8
        var notable: [Int] = []
        if lines.count > head + tail {
            for i in head..<(lines.count - tail) {
                let lower = lines[i].lowercased()
                if notableWords.contains(where: { lower.contains($0) }) { notable.append(i) }
            }
        }
        var out = ["\(lines.count) lines; \(notable.count) in the middle mention errors, warnings or failures."]
        for i in 0..<min(head, lines.count) { out.append(clip("L\(i + 1): \(lines[i])")) }
        if lines.count > head + tail {
            out.append("…")
            var shown = notable
            if shown.count > 30 { shown = Array(shown.prefix(15)) + Array(shown.suffix(15)) }
            for i in shown { out.append(clip("L\(i + 1): \(lines[i])")) }
            out.append("…")
            for i in (lines.count - tail)..<lines.count { out.append(clip("L\(i + 1): \(lines[i])")) }
        }
        return out.joined(separator: "\n")
    }

    private static func clip(_ line: String, limit: Int = 240) -> String {
        line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
