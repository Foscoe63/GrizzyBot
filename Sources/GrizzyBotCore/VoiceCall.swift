import Foundation

/// The rules of a live voice call with one bot: when the person has finished speaking, what gets
/// read aloud, and how a spoken answer maps to an approval. The microphone and speaker live in the
/// app; everything decidable without them is here.
public enum VoiceCall {
    public enum Phase: String, Sendable, Equatable {
        case listening, thinking, speaking, waitingForApproval
    }

    /// Seconds of unchanged transcript that count as "finished speaking".
    public static let silenceSeconds = 1.4
    /// Longest reply read aloud; the rest stays in the chat.
    public static let maxSpokenCharacters = 700

    public enum SpokenDecision: Equatable, Sendable {
        case allow, alwaysAllow, deny, unclear
    }

    /// True when the transcript has stopped changing long enough to send.
    public static func utteranceFinished(transcript: String, lastChange: Date, now: Date = .now) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && now.timeIntervalSince(lastChange) >= silenceSeconds
    }

    /// "hang up", "end call", "goodbye" and similar, as the whole utterance.
    public static func isHangUp(_ utterance: String) -> Bool {
        let t = normalized(utterance)
        return ["hang up", "end call", "end the call", "goodbye", "bye", "stop the call", "that's all", "thats all"].contains(t)
    }

    /// Maps a short spoken answer to an approval. Anything long or ambiguous is `.unclear`: a
    /// misheard sentence must never approve a tool.
    public static func approvalDecision(_ utterance: String) -> SpokenDecision {
        let t = normalized(utterance)
        guard t.split(separator: " ").count <= 4 else { return .unclear }
        if ["always allow", "always", "allow always", "always yes"].contains(t) { return .alwaysAllow }
        if ["allow", "allow it", "yes", "yes please", "yeah", "go ahead", "approve", "approved", "do it", "ok", "okay", "sure"].contains(t) { return .allow }
        if ["deny", "no", "nope", "don't", "do not", "stop", "cancel", "reject", "no thanks"].contains(t) { return .deny }
        return .unclear
    }

    /// What to say when a bot needs an approval.
    public static func approvalPrompt(bot: String) -> String {
        "\(bot) needs your approval. Say allow, always allow, or deny."
    }

    /// Makes a reply fit for speaking: no markdown, code blocks and links summarised, bounded.
    public static func spokenText(_ reply: String) -> String {
        var text = reply
        // Fenced code is not read aloud.
        while let open = text.range(of: "```") {
            if let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
                text.replaceSubrange(open.lowerBound..<close.upperBound, with: " (code is in the chat) ")
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        // [label](url) → label
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        for ch in ["*", "`", "#", "_", ">", "|"] { text = text.replacingOccurrences(of: ch, with: "") }
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: ". ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxSpokenCharacters else { return text }
        let head = String(text.prefix(maxSpokenCharacters))
        // Cut at the last sentence end if there is one past the halfway mark.
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > maxSpokenCharacters / 2 {
            return String(head[...end]) + " The rest is in the chat."
        }
        return head + "… The rest is in the chat."
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
