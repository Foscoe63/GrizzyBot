import Foundation

/// Outgoing messages (email, chat posts) are shown as an editable draft before they leave, rather
/// than as a bare "allow this tool?" prompt. This pulls the readable parts out of a plugin call.
public enum DraftPreview {
    public static let tool = "plugin_call.draft"

    private static let outboundSlugs: Set<String> = [
        "gmail", "outlook", "slack", "discord", "microsoft-teams", "teams", "whatsapp", "telegram", "x", "twitter", "linkedin", "mastodon",
    ]

    public static func isOutbound(slug: String) -> Bool {
        outboundSlugs.contains(slug.lowercased())
    }

    /// Keys that may hold the message text, in preference order.
    static let bodyKeys = ["body", "content", "text", "message"]
    static let toKeys = ["to", "recipient", "recipients", "channel", "user"]
    static let subjectKeys = ["subject", "title"]

    public struct Draft: Equatable, Sendable {
        public var to: String
        public var subject: String
        public var body: String
    }

    public static func draft(argumentsJSON: String) -> Draft {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        func first(_ keys: [String]) -> String {
            for key in keys {
                if let value = args.stringValue(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
            }
            return ""
        }
        return Draft(to: first(toKeys), subject: first(subjectKeys), body: first(bodyKeys))
    }

    /// The text shown on the approval card.
    public static func detail(slug: String, argumentsJSON: String) -> String {
        let d = draft(argumentsJSON: argumentsJSON)
        var lines = ["Via \(slug)"]
        if !d.to.isEmpty { lines.append("To: \(d.to)") }
        if !d.subject.isEmpty { lines.append("Subject: \(d.subject)") }
        lines.append("")
        lines.append(d.body)
        return lines.joined(separator: "\n")
    }

    /// Splits a card's detail back into header lines and body.
    public static func split(detail: String) -> (header: [String], body: String) {
        let parts = detail.components(separatedBy: "\n\n")
        guard parts.count >= 2 else { return ([], detail) }
        return (parts[0].components(separatedBy: "\n"), parts.dropFirst().joined(separator: "\n\n"))
    }

    /// The arguments with the message text replaced by an edited version.
    public static func applying(editedBody: String, to argumentsJSON: String) -> String {
        var object = JSONValue.parseObject(argumentsJSON)
        let key = bodyKeys.first { object[$0] != nil } ?? "body"
        object[key] = .string(editedBody)
        let value = JSONValue.object(object)
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return argumentsJSON }
        return text
    }
}
