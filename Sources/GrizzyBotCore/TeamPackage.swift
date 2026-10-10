import Foundation

/// A whole team — bots, rooms, routines — as one Markdown file a person can read, share, and import.
///
/// The machine-readable part is a fenced JSON block; everything around it is ordinary Markdown so the
/// file also works as a README. A package never carries credentials, chats, memory, or computer
/// access, and anything that looks like a secret is scrubbed from the text on the way out.
public struct TeamPackage: Codable, Sendable, Equatable {
    public static let format = "grizzybot-team/1"
    public static let fence = "grizzybot-team"

    public struct BotSpec: Codable, Sendable, Equatable {
        public var name: String
        public var title: String
        public var description: String
        public var instructions: String
        public var skills: [String]
        public var tools: [String]
        public var chiefOfStaff: Bool
        public var goal: String?

        public init(
            name: String, title: String = "", description: String = "", instructions: String = "",
            skills: [String] = [], tools: [String] = [], chiefOfStaff: Bool = false, goal: String? = nil
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.instructions = instructions
            self.skills = skills
            self.tools = tools
            self.chiefOfStaff = chiefOfStaff
            self.goal = goal
        }
    }

    public struct RoutineSpec: Codable, Sendable, Equatable {
        public var bot: String
        public var name: String
        public var prompt: String
        public var cron: String
        public var heartbeat: Bool
        public var continuity: Bool

        public init(bot: String, name: String, prompt: String, cron: String, heartbeat: Bool = false, continuity: Bool = false) {
            self.bot = bot
            self.name = name
            self.prompt = prompt
            self.cron = cron
            self.heartbeat = heartbeat
            self.continuity = continuity
        }
    }

    public struct RoomSpec: Codable, Sendable, Equatable {
        public var name: String
        public var members: [String]

        public init(name: String, members: [String]) {
            self.name = name
            self.members = members
        }
    }

    public var format: String
    public var name: String
    public var summary: String
    public var bots: [BotSpec]
    public var rooms: [RoomSpec]
    public var routines: [RoutineSpec]

    public init(name: String, summary: String = "", bots: [BotSpec], rooms: [RoomSpec] = [], routines: [RoutineSpec] = []) {
        self.format = Self.format
        self.name = name
        self.summary = summary
        self.bots = bots
        self.rooms = rooms
        self.routines = routines
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case noPackage
        case unsupported(String)
        case invalid(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .noPackage: return "That file doesn't contain a GrizzyBot team."
            case .unsupported(let f): return "This team uses a newer format (\(f)). Update GrizzyBot to import it."
            case .invalid(let why): return "The team file is damaged: \(why)"
            case .empty: return "The team file has no bots in it."
            }
        }
    }

    public static let maxBots = 25

    // MARK: Write

    public func markdown() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var lines = ["---", "format: \(Self.format)", "name: \(Self.oneLine(name))", "---", "", "# \(name)", ""]
        if !summary.isEmpty { lines += [summary, ""] }
        lines.append("## Bots")
        for bot in bots {
            let role = bot.title.isEmpty ? "" : " — \(bot.title)"
            lines.append("- **\(bot.name)**\(role)\(bot.chiefOfStaff ? " (chief of staff)" : "")")
        }
        if !routines.isEmpty {
            lines += ["", "## Routines (they arrive paused)"]
            for r in routines { lines.append("- \(r.name) — \(r.bot), `\(r.cron.isEmpty ? "on events" : r.cron)`") }
        }
        lines += [
            "", "## How to use", "",
            "In GrizzyBot, open Settings → General → Teams → Import team and choose this file. You'll see exactly what it adds before anything is created. No credentials, chats, or memory are included.",
            "", "```\(Self.fence)", json, "```", "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Read

    public static func parse(markdown: String) throws -> TeamPackage {
        guard let open = markdown.range(of: "```\(fence)") else { throw ParseError.noPackage }
        let afterOpen = markdown[open.upperBound...]
        guard let lineEnd = afterOpen.firstIndex(of: "\n"),
              let close = afterOpen[lineEnd...].range(of: "\n```")
        else { throw ParseError.noPackage }
        let json = String(afterOpen[afterOpen.index(after: lineEnd)..<close.lowerBound])
        guard let data = json.data(using: .utf8) else { throw ParseError.invalid("unreadable text") }
        let package: TeamPackage
        do {
            package = try JSONDecoder().decode(TeamPackage.self, from: data)
        } catch {
            throw ParseError.invalid("not valid team data")
        }
        guard package.format.hasPrefix("grizzybot-team/") else { throw ParseError.noPackage }
        guard package.format == Self.format else { throw ParseError.unsupported(package.format) }
        guard !package.bots.isEmpty else { throw ParseError.empty }
        return package
    }

    /// What importing would do, in plain words, for the confirmation screen.
    public func preview() -> String {
        var lines = ["“\(name)” will add:", "• \(bots.count) bot\(bots.count == 1 ? "" : "s"): " + bots.map(\.name).joined(separator: ", ")]
        if !rooms.isEmpty { lines.append("• \(rooms.count) room\(rooms.count == 1 ? "" : "s")") }
        if !routines.isEmpty { lines.append("• \(routines.count) routine\(routines.count == 1 ? "" : "s"), paused until you turn them on") }
        lines.append("Bots start asking before they act. Nothing from the author's accounts, chats, or memory is included.")
        return lines.joined(separator: "\n")
    }
}
