import Foundation

/// Chat commands that belong to GrizzyBot itself rather than to a skill.
public enum BuiltinCommand: String, CaseIterable, Sendable {
    /// Where the context window is going.
    case context
    /// A standing objective the bot keeps working toward across turns.
    case goal
    /// Plan without doing.
    case plan
    /// Squeeze the conversation to free room.
    case compact
    /// Tokens spent by this bot.
    case usage
    /// Undo the file changes a run made.
    case rollback

    public var summary: String {
        switch self {
        case .context: return "show what is filling the context window"
        case .goal: return "set a standing goal (/goal clear to drop it)"
        case .plan: return "write a plan for a task without carrying it out"
        case .compact: return "shrink the conversation to free up context"
        case .usage: return "tokens this bot has used"
        case .rollback: return "undo the last file changes (/rollback list to see them)"
        }
    }

    /// Commands whose reply is produced here, without calling the model.
    public var isLocal: Bool {
        switch self {
        case .context, .compact, .usage, .rollback: return true
        case .goal, .plan: return false
        }
    }
}

public enum BuiltinCommands {
    public static func helpLines() -> [String] {
        BuiltinCommand.allCases.map { "/\($0.rawValue) — \($0.summary)" }
    }

    public static func planPrompt(task: String) -> String {
        """
        Make a plan for the task below. Do NOT carry it out and do not change anything: no writes, no sends, \
        no purchases. You may read or search to make the plan accurate. Reply with a short numbered plan, \
        then list anything you would need to ask the person first.

        Task: \(task)
        """
    }

    public static func goalKickoff(goal: String) -> String {
        "Start working toward your standing goal now: \(goal)"
    }

    public static func isClearGoal(_ argument: String) -> Bool {
        ["clear", "off", "none", "done", "stop"].contains(argument.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Prompt section that keeps a goal in front of the model on every turn.
    public static func goalSection(_ goal: String) -> String? {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return """
        Standing goal (set by the person with /goal): \(trimmed)
        Keep it in mind on every turn. When it is met, say so plainly and call complete. \
        If you are blocked, say exactly what you need from them.
        """
    }
}

/// How the context window is divided, in characters (tokens are roughly a quarter of that).
public struct ContextBreakdown: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var label: String
        public var chars: Int
        public init(label: String, chars: Int) {
            self.label = label
            self.chars = chars
        }
    }

    public var entries: [Entry]
    public var windowChars: Int

    public init(entries: [Entry], windowChars: Int) {
        self.entries = entries
        self.windowChars = max(1, windowChars)
    }

    public var usedChars: Int { entries.reduce(0) { $0 + $1.chars } }

    public static func tokens(_ chars: Int) -> Int { (chars + 3) / 4 }

    public func render() -> String {
        let used = usedChars
        let free = max(0, windowChars - used)
        var lines = ["**Context** — about \(Self.format(Self.tokens(used))) of \(Self.format(Self.tokens(windowChars))) tokens used (\(percent(used))%)", ""]
        for entry in entries where entry.chars > 0 {
            lines.append("\(bar(entry.chars)) \(entry.label): \(Self.format(Self.tokens(entry.chars))) (\(percent(entry.chars))%)")
        }
        lines.append("\(bar(free)) Free: \(Self.format(Self.tokens(free))) (\(percent(free))%)")
        if used > windowChars * 8 / 10 {
            lines.append("")
            lines.append("Getting full — `/compact` will shrink the conversation.")
        }
        return lines.joined(separator: "\n")
    }

    private func percent(_ chars: Int) -> Int {
        Int((Double(chars) / Double(windowChars) * 100).rounded())
    }

    private func bar(_ chars: Int) -> String {
        let cells = max(chars > 0 ? 1 : 0, min(10, Int((Double(chars) / Double(windowChars) * 10).rounded())))
        return String(repeating: "▓", count: cells) + String(repeating: "░", count: 10 - cells)
    }

    static func format(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : String(n)
    }
}
