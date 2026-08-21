import Foundation

/// Chat-box `/command` parsing for skills and a few built-ins.
public enum SlashCommand: Sendable {
    public struct Parsed: Equatable, Sendable {
        public var name: String
        public var argument: String

        public init(name: String, argument: String) {
            self.name = name
            self.argument = argument
        }
    }

    public enum Resolution: Equatable, Sendable {
        /// Force-load this skill; `prompt` is what the agent should answer.
        case skill(AgentSkill, prompt: String)
        /// List available slash skills for this bot.
        case help([AgentSkill])
        case unknown(String)
        /// Ordinary chat — not a slash command.
        case plain(String)
    }

    /// Leading `/name` token (letters, digits, `_`, `-`). Returns nil if the text is not a slash line.
    public static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else {
            return Parsed(name: "help", argument: "")
        }
        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return Parsed(name: "help", argument: "") }
        let name = SkillMarkdown.slug(String(first))
        guard !name.isEmpty else { return nil }
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Parsed(name: name, argument: argument)
    }

    public static func resolve(_ text: String, skills: [AgentSkill]) -> Resolution {
        guard let parsed = parse(text) else {
            return .plain(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if parsed.name == "help" || parsed.name == "skills" || parsed.name == "commands" {
            return .help(skills.sorted { $0.id < $1.id })
        }
        if let match = skills.first(where: {
            $0.id == parsed.name || SkillMarkdown.slug($0.name) == parsed.name
        }) {
            let prompt = parsed.argument.isEmpty
                ? "Follow the /\(match.id) skill."
                : parsed.argument
            return .skill(match, prompt: prompt)
        }
        return .unknown(parsed.name)
    }

    /// Autocomplete while the composer is a single-line `/prefix…` (no argument yet).
    public static func suggestions(draft: String, skills: [AgentSkill], limit: Int = 8) -> [AgentSkill] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        if trimmed.contains(where: { $0.isWhitespace }) { return [] }
        let prefix = SkillMarkdown.slug(String(trimmed.dropFirst()))
        let sorted = skills.sorted { $0.id < $1.id }
        if prefix.isEmpty { return Array(sorted.prefix(limit)) }
        return Array(
            sorted
                .filter {
                    $0.id.hasPrefix(prefix) || SkillMarkdown.slug($0.name).hasPrefix(prefix)
                }
                .prefix(limit)
        )
    }

    public static func helpText(skills: [AgentSkill]) -> String {
        if skills.isEmpty {
            return "No skills enabled for this bot. Open Settings → Skills, or type a normal message."
        }
        let lines = skills.sorted { $0.id < $1.id }.map { skill in
            "/\(skill.id) — \(skill.description)"
        }
        return """
        Slash commands (skills for this bot):
        \(lines.joined(separator: "\n"))

        Example: `/research summarize today’s AI news`
        Also: `/help`
        """
    }
}
