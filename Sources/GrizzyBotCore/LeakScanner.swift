import Foundation

/// IronClaw's two-way secret check: nothing that looks like one of the user's secrets leaves in a
/// tool call, and nothing that is one comes back into the model's context.
///
/// Two kinds of evidence: the exact values GrizzyBot itself holds (provider keys, plugin tokens,
/// webhook secrets) and well-known credential shapes. Words like "password" are deliberately not
/// matched — a bot must be able to write about passwords.
public enum LeakScanner {
    private static let shapes: [(label: String, pattern: String)] = [
        ("Anthropic/OpenAI-style API key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_-]{30,}"#),
        ("AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("JSON web token", #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
    ]

    /// Secrets shorter than this are too likely to collide with ordinary words to match exactly.
    public static let minimumSecretLength = 10

    /// Human-readable reasons the text should not be sent. Empty means clean.
    public static func findings(in text: String, knownSecrets: [String] = []) -> [String] {
        var out: [String] = []
        for secret in usable(knownSecrets) where text.contains(secret) {
            out.append("one of your stored secrets (\(mask(secret)))")
        }
        for shape in shapes where text.range(of: shape.pattern, options: .regularExpression) != nil {
            out.append(shape.label)
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// The text with every stored secret value replaced. Shapes are left alone on the way in: a
    /// README that shows a sample key should still read as one.
    public static func redactKnown(_ text: String, knownSecrets: [String]) -> String {
        var out = text
        for secret in usable(knownSecrets) where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: "[redacted secret]")
        }
        return out
    }

    private static func usable(_ secrets: [String]) -> [String] {
        Array(Set(secrets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= minimumSecretLength }))
    }

    private static func mask(_ secret: String) -> String {
        "\(secret.prefix(3))…\(secret.suffix(2))"
    }

    /// Tools whose arguments travel to someone else.
    public static func sendsOutside(tool name: String) -> Bool {
        UntrustedContent.isExternal(tool: name) || name == "destination_write" || name == "toolport_call_tool"
    }
}
