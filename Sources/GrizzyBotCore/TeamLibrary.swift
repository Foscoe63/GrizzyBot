import Foundation

/// One team a person can browse and install.
public struct TeamLibraryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// https address of the team file. Relative addresses are resolved against the index.
    public var url: String?
    public var bots: Int
    public var tags: [String]

    public init(id: String, name: String, summary: String = "", url: String? = nil, bots: Int = 0, tags: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.url = url
        self.bots = bots
        self.tags = tags
    }
}

/// A list of teams served as JSON, so anyone can host a library:
/// `{"format":"grizzybot-team-index/1","teams":[{"id":"…","name":"…","summary":"…","url":"…","bots":3,"tags":[]}]}`
public struct TeamLibraryIndex: Codable, Sendable, Equatable {
    public static let format = "grizzybot-team-index/1"
    public static let maxEntries = 200

    public var format: String
    public var teams: [TeamLibraryEntry]

    public init(teams: [TeamLibraryEntry]) {
        self.format = Self.format
        self.teams = teams
    }

    public static func parse(_ text: String) throws -> TeamLibraryIndex {
        guard let data = text.data(using: .utf8), let index = try? JSONDecoder().decode(TeamLibraryIndex.self, from: data) else {
            throw TeamPackage.ParseError.invalid("not a team library")
        }
        guard index.format == Self.format else { throw TeamPackage.ParseError.unsupported(index.format) }
        var seen = Set<String>()
        var kept = index
        kept.teams = index.teams.filter { !$0.id.isEmpty && !$0.name.isEmpty && seen.insert($0.id).inserted }
        kept.teams = Array(kept.teams.prefix(maxEntries))
        return kept
    }

    public static func fetch(url: URL, session: URLSession = .shared) async throws -> TeamLibraryIndex {
        var index = try parse(try await TeamPackage.download(url: url, session: session))
        // Make every address absolute now, so a later click never depends on where the index came from.
        index.teams = index.teams.map { entry in
            var e = entry
            if let raw = entry.url, let resolved = URL(string: raw, relativeTo: url)?.absoluteURL { e.url = resolved.absoluteString }
            return e
        }
        return index
    }
}

/// Teams that ship inside GrizzyBot, so the library is useful with no network and no account.
public enum TeamLibrary {
    public static let starters: [TeamPackage] = [newsroom, supportDesk, researchLab]

    public static func entry(for package: TeamPackage) -> TeamLibraryEntry {
        TeamLibraryEntry(
            id: package.name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: package.name, summary: package.summary, bots: package.bots.count,
            tags: package.departments.map(\.name)
        )
    }

    private static let readOnly = ["read_file", "list_files", "web_search", "remember", "search_memory"]

    static let newsroom = TeamPackage(
        name: "Newsroom",
        summary: "Find stories, draft them, and have a second bot check the facts before anything is final.",
        bots: [
            .init(name: "Editor", title: "Chief of staff", description: "Assigns work and keeps the desk moving.",
                  instructions: "You run the desk. Break requests into assignments for Reporter and Fact Checker, collect their work, and return one clean piece. Say plainly what is unverified.",
                  tools: readOnly + ["message_bot"], chiefOfStaff: true),
            .init(name: "Reporter", title: "Finds and drafts", description: "Researches a topic and writes the first draft.",
                  instructions: "Research the topic with web search, keep a list of sources with links, and write a tight first draft. Never invent a quote or a number.",
                  tools: readOnly + ["write_file"]),
            .init(name: "Fact Checker", title: "Checks claims", description: "Verifies every claim in a draft against its sources.",
                  instructions: "Go through a draft claim by claim. Mark each as confirmed, unclear, or wrong, with the source you used. Be skeptical and short.",
                  tools: readOnly),
        ],
        rooms: [.init(name: "Desk", members: ["Editor", "Reporter", "Fact Checker"])],
        routines: [.init(bot: "Editor", name: "Morning brief", prompt: "Summarise the three most important stories in my areas of interest and propose assignments.", cron: "0 8 * * 1-5")],
        connectors: [.init(slug: "gmail", name: "Gmail", why: "Lets the Editor read press releases in your inbox")],
        departments: [.init(name: "Newsroom", bots: ["Editor", "Reporter", "Fact Checker"], rooms: ["Desk"])]
    )

    static let supportDesk = TeamPackage(
        name: "Support Desk",
        summary: "Triage incoming questions, draft replies, and escalate the hard ones to you.",
        bots: [
            .init(name: "Triage", title: "Sorts requests", description: "Labels each request and routes it.",
                  instructions: "Read each request, label it (bug, how-to, billing, other) with a one-line reason, and hand it to Responder. Flag anything urgent or angry for the human.",
                  tools: readOnly + ["message_bot"], chiefOfStaff: true),
            .init(name: "Responder", title: "Drafts replies", description: "Writes a reply for each request.",
                  instructions: "Draft a friendly, specific reply. Use the knowledge you have; if you do not know, say so and ask for what you need. Never promise refunds or dates.",
                  tools: readOnly),
        ],
        rooms: [.init(name: "Inbox", members: ["Triage", "Responder"])],
        connectors: [
            .init(slug: "gmail", name: "Gmail", why: "Where requests arrive", required: true),
            .init(slug: "slack", name: "Slack", why: "For escalations"),
        ],
        departments: [.init(name: "Support", bots: ["Triage", "Responder"], rooms: ["Inbox"])]
    )

    static let researchLab = TeamPackage(
        name: "Research Lab",
        summary: "Two departments: one gathers sources, one turns them into a brief you can act on.",
        bots: [
            .init(name: "Scout", title: "Finds sources", description: "Collects and ranks sources on a question.",
                  instructions: "Given a question, find the best primary sources, rank them by reliability, and save short notes with links.",
                  tools: readOnly + ["write_file"]),
            .init(name: "Librarian", title: "Keeps notes", description: "Files and recalls what the lab has learned.",
                  instructions: "Keep the lab's findings organised. Remember durable facts with their sources and answer recall questions precisely.",
                  tools: readOnly),
            .init(name: "Analyst", title: "Writes the brief", description: "Turns notes into a decision-ready brief.",
                  instructions: "Read the notes and write a one-page brief: the answer first, then evidence, then what is still uncertain.",
                  tools: readOnly + ["write_file"], chiefOfStaff: true),
        ],
        rooms: [.init(name: "Sources", members: ["Scout", "Librarian"])],
        departments: [
            .init(name: "Gathering", bots: ["Scout", "Librarian"], rooms: ["Sources"]),
            .init(name: "Briefing", bots: ["Analyst"]),
        ]
    )
}
