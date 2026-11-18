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

    /// An account the team works better with. A checklist only: nothing is connected on import.
    public struct ConnectorSpec: Codable, Sendable, Equatable {
        public var slug: String
        public var name: String
        public var why: String
        public var required: Bool

        public init(slug: String, name: String = "", why: String = "", required: Bool = false) {
            self.slug = slug
            self.name = name.isEmpty ? slug : name
            self.why = why
            self.required = required
        }
    }

    /// A named slice of the team (bots and rooms by name) that can be installed on its own.
    public struct DepartmentSpec: Codable, Sendable, Equatable {
        public var name: String
        public var bots: [String]
        public var rooms: [String]

        public init(name: String, bots: [String], rooms: [String] = []) {
            self.name = name
            self.bots = bots
            self.rooms = rooms
        }
    }

    public var format: String
    public var name: String
    public var summary: String
    public var bots: [BotSpec]
    public var rooms: [RoomSpec]
    public var routines: [RoutineSpec]
    /// Optional in the file: teams written before these existed still import.
    public var connectors: [ConnectorSpec]
    public var departments: [DepartmentSpec]

    public init(
        name: String, summary: String = "", bots: [BotSpec], rooms: [RoomSpec] = [], routines: [RoutineSpec] = [],
        connectors: [ConnectorSpec] = [], departments: [DepartmentSpec] = []
    ) {
        self.format = Self.format
        self.name = name
        self.summary = summary
        self.bots = bots
        self.rooms = rooms
        self.routines = routines
        self.connectors = connectors
        self.departments = departments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        bots = try c.decode([BotSpec].self, forKey: .bots)
        rooms = try c.decodeIfPresent([RoomSpec].self, forKey: .rooms) ?? []
        routines = try c.decodeIfPresent([RoutineSpec].self, forKey: .routines) ?? []
        connectors = try c.decodeIfPresent([ConnectorSpec].self, forKey: .connectors) ?? []
        departments = try c.decodeIfPresent([DepartmentSpec].self, forKey: .departments) ?? []
    }

    /// Bots that no department claims.
    public var ungroupedBots: [BotSpec] {
        let grouped = Set(departments.flatMap(\.bots))
        return bots.filter { !grouped.contains($0.name) }
    }

    /// Only the named departments: their bots, the rooms and routines that belong to them, and the
    /// connectors (kept whole, since a checklist is cheap). Unknown names are ignored. Bots that no
    /// department claims come along only when `includeUngrouped` is true.
    public func restricted(toDepartments names: [String], includeUngrouped: Bool = false) -> TeamPackage {
        let wanted = Set(names.map { $0.lowercased() })
        let chosen = departments.filter { wanted.contains($0.name.lowercased()) }
        var botNames = Set(chosen.flatMap(\.bots))
        if includeUngrouped { botNames.formUnion(ungroupedBots.map(\.name)) }
        let roomNames = Set(chosen.flatMap(\.rooms))
        var copy = self
        copy.bots = bots.filter { botNames.contains($0.name) }
        copy.rooms = rooms.filter { roomNames.contains($0.name) || Set($0.members).isSubset(of: botNames) }
        copy.routines = routines.filter { botNames.contains($0.bot) }
        copy.departments = chosen
        return copy
    }

    /// Groups bots into departments from a bot-name → department-name map. A room joins a department
    /// when every member is in it. Blank department names mean "no department".
    public static func departments(from assignments: [String: String], rooms: [RoomSpec] = [], order: [String] = []) -> [DepartmentSpec] {
        var members: [String: [String]] = [:]
        var names: [String] = []
        for bot in order.isEmpty ? assignments.keys.sorted() : order {
            let dept = (assignments[bot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dept.isEmpty else { continue }
            if members[dept] == nil { names.append(dept) }
            members[dept, default: []].append(bot)
        }
        return names.map { dept in
            let bots = members[dept] ?? []
            let owned = rooms.filter { !$0.members.isEmpty && Set($0.members).isSubset(of: Set(bots)) }.map(\.name)
            return DepartmentSpec(name: dept, bots: bots, rooms: owned)
        }
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
        if !departments.isEmpty {
            lines += ["", "## Departments"]
            for d in departments { lines.append("- **\(d.name)** — \(d.bots.joined(separator: ", "))") }
        }
        if !connectors.isEmpty {
            lines += ["", "## Accounts to connect"]
            for c in connectors { lines.append("- [ ] \(c.name)\(c.required ? " (needed)" : "")\(c.why.isEmpty ? "" : " — \(c.why)")") }
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
        if !departments.isEmpty { lines.append("• \(departments.count) department\(departments.count == 1 ? "" : "s"): " + departments.map(\.name).joined(separator: ", ")) }
        if !routines.isEmpty { lines.append("• \(routines.count) routine\(routines.count == 1 ? "" : "s"), paused until you turn them on") }
        if !connectors.isEmpty { lines.append("• Works best with: " + connectors.map(\.name).joined(separator: ", ") + " (you'll get a checklist; nothing is connected for you)") }
        lines.append("Bots start asking before they act. Nothing from the author's accounts, chats, or memory is included.")
        return lines.joined(separator: "\n")
    }

    // MARK: Fetch

    public static let maxDownloadBytes = 512 * 1024

    /// Downloads a small https text file. Used for team files and library indexes.
    public static func download(url: URL, session: URLSession = .shared) async throws -> String {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw ParseError.invalid("only https links can be imported")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/markdown, text/plain, application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParseError.invalid("the server answered \(http.statusCode)")
        }
        if response.expectedContentLength > Int64(maxDownloadBytes) { throw ParseError.invalid("the file is too large") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDownloadBytes { throw ParseError.invalid("the file is too large") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.invalid("unreadable text") }
        return text
    }

    /// Accepts only HTTPS links; the file still goes through `parse` and the confirmation screen.
    public static func fetch(url: URL, session: URLSession = .shared) async throws -> TeamPackage {
        try parse(markdown: try await download(url: url, session: session))
    }

    /// Reads a local team file, refusing anything unreasonably large.
    public static func load(file url: URL) throws -> TeamPackage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxDownloadBytes else { throw ParseError.invalid("the file is too large") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ParseError.invalid("unreadable text")
        }
        return try parse(markdown: text)
    }
}
