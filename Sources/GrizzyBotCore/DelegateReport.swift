import Foundation

/// How a handed-off job is reported back to the bot that handed it over. A delegate whose run
/// "completed" without producing anything — empty, or only its own working-out — must read as a
/// failure, not as an answer.
public enum DelegateReport {
    /// True when `text` is a model thinking aloud rather than reporting: a long run of
    /// self-correction ("Wait,", "Hmm", "Let me reconsider") and no deliverable shape (table, headings).
    public static func looksLikeScratchpad(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 800 else { return false }
        let lower = body.lowercased()
        var hits = 0
        for marker in markers {
            hits += lower.components(separatedBy: marker).count - 1
        }
        guard hits >= 8 else { return false }
        let hasTable = lower.contains("|---") || lower.contains("| ---")
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("#") }.count
        return !hasTable && headings < 2
    }

    private static let markers = [
        "wait,", "wait —", "wait.", "hmm", "let me think", "let me try", "let me reconsider",
        "let me step back", "actually,", "i need to", "i should", "key insight", "ok, ", "okay,",
        "this is really", "frustrating",
    ]

    /// The one line a lead should read when a delegate did not deliver.
    public static func failureNotice(peer: String, task: String, reason: String, lastWords: String = "") -> String {
        var text = "\(peer) did not finish the job you handed over (“\(task.prefix(80))”): \(reason)"
        let tail = lastWords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            text += "\n\nWhere it got stuck: " + String(tail.suffix(240)).replacingOccurrences(of: "\n", with: " ")
        }
        text += "\n\nDo it yourself, or hand \(peer) a narrower job."
        return text
    }

    /// Decide what to tell the lead about a finished peer run. `nil` means the reply is a real answer.
    public static func shortfall(reply: String) -> String? {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "it finished without writing anything back." }
        if looksLikeScratchpad(body) {
            return "it ended without a result — what it wrote back was working-out, not an answer."
        }
        return nil
    }
}

/// A bot the lead has handed work to and is still waiting on.
public struct PeerWait: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var since: Date
    /// What the peer is doing now: running, or held up for the person.
    public var needsUser: Bool

    public var label: String { needsUser ? "needs you" : "working" }
}
