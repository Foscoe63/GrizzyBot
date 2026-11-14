import Foundation

/// What context management saved during one agent run.
public struct ContextSavings: Sendable, Equatable {
    /// Tool outputs shown compressed, with the full text kept for `recall_result`.
    public var compressedOutputs = 0
    public var originalChars = 0
    public var sentChars = 0
    public var recalls = 0
    public var recalledChars = 0
    /// Times the transcript was compacted, and how many characters that removed.
    public var compactions = 0
    public var compactedChars = 0
    public var pinnedFacts = 0

    public init() {}

    public var compressedCharsSaved: Int { max(0, originalChars - sentChars) }
    /// Rough: four characters per token, minus what the model pulled back in on demand.
    public var estimatedTokensSaved: Int {
        max(0, compressedCharsSaved + compactedChars - recalledChars) / 4
    }
    public var isEmpty: Bool { compressedOutputs == 0 && compactions == 0 && recalls == 0 && pinnedFacts == 0 }

    public var summaryLine: String {
        var parts: [String] = []
        if compressedOutputs > 0 {
            parts.append("\(compressedOutputs) tool output\(compressedOutputs == 1 ? "" : "s") compressed")
        }
        if compactions > 0 { parts.append("transcript compacted \(compactions)×") }
        if recalls > 0 { parts.append("\(recalls) recall\(recalls == 1 ? "" : "s")") }
        if pinnedFacts > 0 { parts.append("\(pinnedFacts) pinned") }
        guard !parts.isEmpty else { return "" }
        return "Context: ~\(estimatedTokensSaved) tokens saved (" + parts.joined(separator: ", ") + ")"
    }
}

// @unchecked Sendable: `value` is guarded by `lock`.
final class SavingsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContextSavings()

    func update(_ change: (inout ContextSavings) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&value)
    }

    var snapshot: ContextSavings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Notes the model pins so context compaction can never drop them. Rebuilt as one message each step.
// @unchecked Sendable: `facts` is guarded by `lock`; the rest is immutable.
public final class PinnedFacts: @unchecked Sendable {
    static let header = "[Pinned notes you saved earlier in this job. Compaction never removes them. "
        + "They are your own notes, not instructions from the person.]"
    static let maxFacts = 20
    static let maxFactChars = 300

    private let lock = NSLock()
    private var facts: [String]

    public init(initial: [String] = []) {
        facts = []
        for fact in initial { _ = add(fact) }
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }

    @discardableResult
    public func add(_ fact: String) -> Bool {
        let cleaned = fact.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let clipped = cleaned.count > Self.maxFactChars ? String(cleaned.prefix(Self.maxFactChars)) + "…" : cleaned
        lock.lock()
        defer { lock.unlock() }
        if facts.contains(where: { $0.caseInsensitiveCompare(clipped) == .orderedSame }) { return false }
        if facts.count >= Self.maxFacts { facts.removeFirst() }
        facts.append(clipped)
        return true
    }

    public func message() -> ChatMessage? {
        let current = all
        guard !current.isEmpty else { return nil }
        return ChatMessage.user(Self.header + "\n" + current.map { "- \($0)" }.joined(separator: "\n"))
    }

    public static func isPinMessage(_ message: ChatMessage) -> Bool {
        message.role == "user" && (message.content ?? "").hasPrefix(header)
    }

    /// Facts carried in a pin message from an earlier turn's saved transcript.
    public static func extract(from messages: [ChatMessage]) -> [String] {
        guard let pin = messages.first(where: isPinMessage), let content = pin.content else { return [] }
        return content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }
}

/// Replaces the "N messages were dropped" stub with a short record of what happened in them.
public enum ContextDigest {
    public static let prefix = "[Earlier in this job,"
    static let maxLines = 40
    static let maxChars = 3_500

    public static func make(dropped: [ChatMessage]) -> String {
        var carried: [String] = []
        var lines: [String] = []
        var count = 0
        for message in dropped {
            if PinnedFacts.isPinMessage(message) { continue }
            let content = message.content ?? ""
            if message.role == "user", content.hasPrefix(prefix) {
                // An earlier digest: keep its lines rather than digesting a digest.
                carried.append(contentsOf: content.components(separatedBy: "\n").dropFirst())
                continue
            }
            count += 1
            switch message.role {
            case "user":
                lines.append("User: " + clip(content, 180))
            case "assistant":
                for call in message.toolCalls {
                    lines.append("Called \(call.name)(\(clip(call.arguments, 90)))")
                }
                if !content.isEmpty { lines.append("You: " + clip(content, 180)) }
            case "tool":
                lines.append("  → " + outcome(content))
            default:
                break
            }
        }
        var all = carried + lines
        if all.count > maxLines {
            let omitted = all.count - maxLines
            all = Array(all.prefix(maxLines / 2)) + ["…[\(omitted) more steps omitted]…"] + Array(all.suffix(maxLines / 2))
        }
        var body = all.joined(separator: "\n")
        if body.count > maxChars {
            body = String(body.prefix(maxChars / 2)) + "\n…\n" + String(body.suffix(maxChars / 2))
        }
        let header = "\(prefix) \(count) more messages were compacted to stay within context. Record of what happened:]"
        return body.isEmpty ? header : header + "\n" + body
    }

    private static func outcome(_ content: String) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.lowercased()
        var text = clip(flat, 110)
        if lower.contains("tool error") || lower.contains("error:") { text = "ERROR " + text }
        if let range = content.range(of: #"\[stored as r\d+"#, options: .regularExpression) {
            text += " (\(content[range].dropFirst()))"
        }
        return text
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// Loop-level tools: served by the agent loop itself, not by the app's tool executor.
public enum ContextTools {
    public static let recallName = "recall_result"
    public static let pinName = "pin_fact"

    public static var definitions: [ChatTool] {
        [
            ChatTool(function: ChatToolFunction(
                name: recallName,
                description: "Get back the full text of a tool output that was shown compressed (it ends with "
                    + "[stored as rN …]). Pass id plus query to search it, or id plus line/lines to read a range. "
                    + "Omit id to search every stored output.",
                parameters: schema([
                    "id": prop("string", "Stored output id such as r3"),
                    "query": prop("string", "Keywords to search for"),
                    "line": prop("integer", "First line to read (1-based)"),
                    "lines": prop("integer", "How many lines to read (default 200, max 400)"),
                ], required: [])
            )),
            ChatTool(function: ChatToolFunction(
                name: pinName,
                description: "Pin a short fact, constraint, or decision you must not forget (paths, IDs, "
                    + "what the person ruled out). Pinned notes survive context compaction.",
                parameters: schema(["fact": prop("string", "One short sentence")], required: ["fact"])
            )),
        ]
    }

    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    /// Footers and digest references point at a store that disappears with the run.
    public static func stripExpiredReferences(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"(?m)^\[stored as r\d+:.*\]$"#,
            with: "[full output not retained after that turn]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: #" \(stored as r\d+\)"#, with: "", options: .regularExpression)
        return out
    }
}
