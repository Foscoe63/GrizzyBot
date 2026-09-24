import Foundation

// MARK: - Avatar shapes

/// Body shape for a bot's avatar (the visor and colour sit on top of it).
/// Raw values are persisted in `Bot.avatarShape`; nil means the default circle.
public enum BotAvatarShape: String, Codable, Sendable, CaseIterable, Identifiable {
    case circle
    case squircle
    case pill
    case hexagon
    case triangle
    case diamond

    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }

    public static func resolve(_ raw: String?) -> BotAvatarShape {
        raw.flatMap(BotAvatarShape.init(rawValue:)) ?? .circle
    }
}

// MARK: - Bot Chat log

/// One bot-to-bot handoff made with `message_bot`, kept so the traffic between
/// bots is visible in one place instead of only in the receiving bot's thread.
public struct BotChatEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case sent
        case answered
        case needsUser
        case failed
    }

    public var id: String
    public var fromBotId: String
    public var toBotId: String
    public var text: String
    public var reply: String?
    public var outcome: Outcome
    public var createdAt: Date

    public init(
        id: String = Ids.new(),
        fromBotId: String,
        toBotId: String,
        text: String,
        reply: String? = nil,
        outcome: Outcome = .sent,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fromBotId = fromBotId
        self.toBotId = toBotId
        self.text = text
        self.reply = reply
        self.outcome = outcome
        self.createdAt = createdAt
    }

    /// The log is a convenience view, not a transcript; cap it so it can't grow
    /// without bound in the workspace file.
    public static let retentionLimit = 500
}

// MARK: - Room @mentions

public enum GroupMentions {
    /// Most bot turns a single user message may trigger in a room, counting
    /// bots pulled in by another bot's reply.
    public static let maxTurns = 6

    public struct Parsed: Sendable, Equatable {
        /// `@everyone` / `@all` appeared.
        public var everyone: Bool
        /// Member bot ids in order of first mention.
        public var botIds: [String]
    }

    /// Resolves `@name` handles against room members. A handle matches a bot's
    /// name case-insensitively, with or without spaces, hyphens and underscores
    /// (`@ResearchBot`, `@research-bot`); trailing punctuation is ignored.
    public static func parse(_ text: String, members: [Bot]) -> Parsed {
        var handles: [String: String] = [:]
        for bot in members {
            let name = bot.name.lowercased()
            for form in [name, collapse(name), name.split(separator: " ").first.map(String.init) ?? ""]
            where !form.isEmpty && handles[form] == nil {
                handles[form] = bot.id
            }
        }

        var everyone = false
        var ids: [String] = []
        for handle in extractHandles(text) {
            if handle == "everyone" || handle == "all" {
                everyone = true
            } else if let id = handles[handle] ?? handles[collapse(handle)], !ids.contains(id) {
                ids.append(id)
            }
        }
        return Parsed(everyone: everyone, botIds: ids)
    }

    /// Who answers a user message: everyone on `@everyone`, else the mentioned
    /// members, else nil so the caller applies the room's default responder.
    public static func responders(for text: String, members: [Bot]) -> [String]? {
        let parsed = parse(text, members: members)
        if parsed.everyone { return members.map(\.id) }
        return parsed.botIds.isEmpty ? nil : parsed.botIds
    }

    private static func collapse(_ s: String) -> String {
        s.filter { !" -_.".contains($0) }
    }

    private static func extractHandles(_ text: String) -> [String] {
        var handles: [String] = []
        var current: String?
        var previous: Character = " "
        for ch in text {
            if let h = current {
                if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                    current = h + String(ch).lowercased()
                    previous = ch
                    continue
                }
                handles.append(h.trimmingCharacters(in: CharacterSet(charactersIn: "._-")))
                current = nil
            }
            // An "@" starts a handle only at a word boundary, so emails don't match.
            if ch == "@", previous.isWhitespace || "([{\"'".contains(previous) {
                current = ""
            }
            previous = ch
        }
        if let h = current { handles.append(h.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))) }
        return handles.filter { !$0.isEmpty }
    }
}
