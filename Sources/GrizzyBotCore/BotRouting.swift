import Foundation

/// What a bot can do, in plain categories. Derived from the tools and skills the person has switched
/// on for it, so it can never claim more than the bot actually has.
public enum BotAbility: String, CaseIterable, Sendable, Codable {
    case web, files, shell, computer, mail, memory, artifacts, delegation

    public var label: String {
        switch self {
        case .web: return "web"
        case .files: return "files"
        case .shell: return "shell"
        case .computer: return "computer"
        case .mail: return "plugins/mail"
        case .memory: return "memory"
        case .artifacts: return "documents"
        case .delegation: return "delegation"
        }
    }

    /// Tool ids that grant the ability.
    var tools: [String] {
        switch self {
        case .web: return ["web_search", "web_fetch"]
        case .files: return ["read_file", "write_file", "edit_file", "list_files", "move_file", "delete_file"]
        case .shell: return ["shell"]
        case .computer: return ["computer_open", "computer_screenshot", "computer_click", "request_takeover"]
        case .mail: return ["plugin_call", "destination_write"]
        case .memory: return ["remember", "search_memory"]
        case .artifacts: return ["artifact_create", "artifact_update", "artifact_rewrite"]
        case .delegation: return ["spawn_bot", "message_bot"]
        }
    }

    /// Phrases that mean a request cannot be done without this ability. Kept narrow on purpose: a
    /// cue that fires on ordinary words ("login", "document") would wrongly rule out the right bot.
    var cues: [String] {
        switch self {
        case .web: return ["search the web", "web search", "google ", "look up", "browse", "website", "url", "http", "latest news", "online"]
        case .files: return [" file", "folder", "directory", " csv"]
        case .shell: return ["run the tests", "terminal", "command line", "shell", "install ", "compile", " git ", "npm ", "brew "]
        case .computer: return ["click ", "screenshot", "on screen", "my desktop", "open the app"]
        case .mail: return ["email", "e-mail", "inbox", "gmail", "calendar", "meeting", "slack"]
        case .memory, .artifacts, .delegation: return []
        }
    }
}

/// A bot as the router sees it.
public struct BotProfile: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var instructions: String
    public var tools: Set<String>
    public var skills: [String]
    public var isChiefOfStaff: Bool

    public init(
        id: String,
        name: String,
        title: String = "",
        description: String = "",
        instructions: String = "",
        tools: Set<String> = [],
        skills: [String] = [],
        isChiefOfStaff: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.instructions = String(instructions.prefix(600))
        self.tools = tools
        self.skills = skills
        self.isChiefOfStaff = isChiefOfStaff
    }

    public var abilities: [BotAbility] {
        BotAbility.allCases.filter { ability in ability.tools.contains { tools.contains($0) } }
    }

    /// "web, files, shell" — what shows in the roster and in router prompts.
    public var abilitySummary: String {
        abilities.map(\.label).joined(separator: ", ")
    }

    public func has(_ ability: BotAbility) -> Bool { abilities.contains(ability) }
}

public struct RouteDecision: Sendable, Equatable {
    public var botId: String
    public var botName: String
    /// 0...1. Rules use the score gap; a model route is 0.8 unless it says it is unsure.
    public var confidence: Double
    public var reason: String
    public var source: Source

    public enum Source: String, Sendable { case mention, rules, model }
}

/// Picks which bot should take a message. Rules first: free, instant, explainable, and the same answer
/// every time. A model can be layered on top (see `ModelRouting`), but never replaces the rules'
/// safety checks: only bots passed in as candidates can be chosen.
public enum BotRouter {
    /// Words that carry no signal about who should do the work.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "from", "have", "has", "had", "are", "was", "were",
        "can", "could", "would", "should", "will", "please", "just", "about", "into", "out", "get", "got", "make", "need",
        "want", "like", "some", "any", "all", "its", "it's", "what", "when", "where", "who", "how", "why", "not", "but",
        "then", "them", "they", "there", "here", "also", "very", "more", "most", "than", "does", "did", "doing", "done",
        "bot", "help", "thanks", "thank", "hello", "hey", "okay", "yes", "yeah",
        // Everyday verbs that every kind of bot does; they say nothing about who should do this one.
        "write", "writes", "read", "reads", "find", "finds", "give", "show", "tell", "look", "check", "use", "run", "runs", "send", "take", "put", "try", "keep",
    ]

    /// Words that mean the same kind of work. A request for "a bug fix" should meet a bot described as
    /// a "coder" even though they share no word.
    private static let concepts: [String: Set<String>] = [
        "~code": ["code", "coder", "coding", "program", "programmer", "software", "bug", "refactor", "function", "compile", "debug", "developer", "repo", "commit", "test"],
        "~research": ["research", "researcher", "search", "source", "cite", "citation", "news", "article", "investigate", "compare", "web"],
        "~mail": ["email", "mail", "inbox", "calendar", "meeting", "schedule", "invite", "slack", "message"],
        "~write": ["write", "writer", "draft", "report", "essay", "blog", "copy", "proofread", "summary", "slides", "deck"],
        "~data": ["data", "spreadsheet", "csv", "chart", "analysis", "analyst", "numbers", "table"],
        "~ops": ["deploy", "server", "infrastructure", "devops", "monitor", "logs", "uptime", "backup"],
    ]

    static let abilityConcept: [BotAbility: String] = [.web: "~research", .mail: "~mail", .shell: "~code"]

    /// The kinds of work a message asks for.
    static func messageConcepts(_ message: String) -> Set<String> {
        Set(tokens(message).filter { $0.hasPrefix("~") })
    }

    /// The kinds of work a bot is set up for (its words and its tools).
    static func profileConcepts(_ p: BotProfile) -> Set<String> {
        var out = Set(tokens([p.name, p.title, p.description, p.skills.joined(separator: " ")].joined(separator: " ")).filter { $0.hasPrefix("~") })
        for ability in p.abilities { if let c = abilityConcept[ability] { out.insert(c) } }
        return out
    }

    static func tokens(_ text: String) -> [String] {
        let base = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
            .map(stem)
        // Both the stemmed word and its concept, so "coder" and "bug" meet at "~code".
        let raw = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var out = base
        for (concept, words) in concepts where !raw.isDisjoint(with: words) || !Set(base).isDisjoint(with: words.map(stem)) {
            out.append(concept)
        }
        return out
    }

    /// Cheap plural/-ing/-ed folding so "researching" and "research", "emails" and "email" meet.
    static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ed", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 4 {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w
    }

    public static func requiredAbilities(in message: String) -> Set<BotAbility> {
        let text = " " + message.lowercased() + " "
        return Set(BotAbility.allCases.filter { ability in ability.cues.contains { text.contains($0) } })
    }

    public struct Scored: Sendable, Equatable {
        public var profile: BotProfile
        public var score: Double
        public var matched: [String]
        public var missing: [BotAbility]
        /// True when the match rests on who the bot is (name, title, description, skills, tools), not
        /// only on a passing word in its free-form instructions.
        public var strong: Bool
    }

    /// Candidates best first. Deterministic: ties fall back to name order.
    public static func rank(message: String, candidates: [BotProfile]) -> [Scored] {
        let messageTokens = Set(tokens(message))
        let required = requiredAbilities(in: message)
        guard !candidates.isEmpty else { return [] }

        // Role text per bot, weighted: who they say they are counts most, then what they are for.
        func weightedTokens(_ p: BotProfile) -> [String: Double] {
            var out: [String: Double] = [:]
            func add(_ text: String, _ weight: Double, concepts: Bool = true) {
                for t in Set(tokens(text)) {
                    // A shared concept ("coder" ~ "bug") is weaker evidence than the same word, and a
                    // passing mention in free-form instructions is not evidence of a speciality.
                    if t.hasPrefix("~") && !concepts { continue }
                    out[t] = max(out[t] ?? 0, t.hasPrefix("~") ? weight * 0.6 : weight)
                }
            }
            add(p.name, 3)
            add(p.title, 3)
            add(p.description, 2)
            add(p.skills.joined(separator: " "), 2)
            add(p.instructions, 1, concepts: false)
            for ability in p.abilities { if let c = abilityConcept[ability] { out[c] = max(out[c] ?? 0, 1.2) } }
            return out
        }
        let weighted = candidates.map(weightedTokens)
        let n = Double(candidates.count)

        return zip(candidates, weighted).map { profile, tokenWeights in
            var score = 0.0
            var matched: [String] = []
            var strong = false
            for token in messageTokens {
                guard let weight = tokenWeights[token] else { continue }
                let df = Double(weighted.filter { $0[token] != nil }.count)
                // A word only one bot has is worth more than a word every bot has.
                let idf = log(1 + n / max(1, df))
                score += weight * idf
                matched.append(token)
                if weight >= 1.2 { strong = true }
            }
            var missing: [BotAbility] = []
            for ability in required {
                if profile.has(ability) { score += 1.5 } else { score -= 2.0; missing.append(ability) }
            }
            return Scored(profile: profile, score: score, matched: matched.sorted(), missing: missing.sorted { $0.rawValue < $1.rawValue }, strong: strong)
        }
        .sorted { a, b in
            a.score != b.score ? a.score > b.score : a.profile.name.localizedCaseInsensitiveCompare(b.profile.name) == .orderedAscending
        }
    }

    public struct Thresholds: Sendable {
        public var minScore: Double
        public var minMargin: Double
        public init(minScore: Double, minMargin: Double) { self.minScore = minScore; self.minMargin = minMargin }
        /// For a room's un-addressed message: a wrong guess is cheap (the person sees who answered).
        public static let room = Thresholds(minScore: 2.5, minMargin: 1.0)
        /// For handing the work away from the bot you asked: only when it is clearly someone else's.
        public static let dispatch = Thresholds(minScore: 4.5, minMargin: 2.0)
    }

    public static func decide(message: String, candidates: [BotProfile], thresholds: Thresholds) -> RouteDecision? {
        let ranked = rank(message: message, candidates: candidates)
        guard let top = ranked.first, top.missing.isEmpty, top.strong else { return nil }
        guard top.score >= thresholds.minScore else { return nil }
        // A request that spans several kinds of work ("research this and email it") is one no single
        // specialist should swallow whole; leave it to whoever coordinates.
        let wanted = messageConcepts(message)
        if wanted.count >= 2, !wanted.isSubset(of: profileConcepts(top.profile)) { return nil }
        if let second = ranked.dropFirst().first, top.score - second.score < thresholds.minMargin { return nil }
        let second = ranked.dropFirst().first?.score ?? 0
        let confidence = min(1, max(0, (top.score - second) / max(top.score, 0.001)))
        return RouteDecision(
            botId: top.profile.id,
            botName: top.profile.name,
            confidence: confidence,
            reason: reason(for: top, message: message),
            source: .rules
        )
    }

    static func reason(for scored: Scored, message: String) -> String {
        var parts: [String] = []
        if !scored.matched.isEmpty { parts.append("matches “\(scored.matched.prefix(3).joined(separator: ", "))”") }
        let needed = requiredAbilities(in: message).filter { scored.profile.has($0) }.map(\.label).sorted()
        if !needed.isEmpty { parts.append("has \(needed.joined(separator: " + "))") }
        if !scored.profile.title.isEmpty { parts.append(scored.profile.title) }
        return parts.isEmpty ? "best fit" : parts.joined(separator: " · ")
    }

    /// `@Name` handles first: an explicit mention beats any scoring.
    public static func mention(in message: String, candidates: [BotProfile]) -> RouteDecision? {
        let probes = candidates.map { Bot(id: $0.id, name: $0.name, color: "#000000", threadId: "") }
        guard let id = GroupMentions.parse(message, members: probes).botIds.first,
              let match = candidates.first(where: { $0.id == id }) else { return nil }
        return RouteDecision(botId: id, botName: match.name, confidence: 1, reason: "you mentioned @\(match.name)", source: .mention)
    }
}

/// Asking a model to choose, for messages the rules cannot call. The reply is validated hard: anything
/// that is not exactly one of the candidates is treated as "no opinion".
public enum ModelRouting {
    public static func messages(for message: String, candidates: [BotProfile]) -> [ChatMessage] {
        let list = candidates.map { c -> String in
            var line = "- id: \(c.id) | name: \(c.name)"
            if !c.title.isEmpty { line += " | role: \(c.title)" }
            if !c.description.isEmpty, c.description != c.title { line += " | about: \(String(c.description.prefix(160)))" }
            let abilities = c.abilitySummary
            if !abilities.isEmpty { line += " | can: \(abilities)" }
            return line
        }.joined(separator: "\n")
        let system = """
        You route messages to the best assistant. Choose exactly one from the list, or none if the message is small talk, \
        is about the assistants themselves, or no one is clearly better than the rest. Judge by what each assistant is for and \
        what it can do. Never invent an id. Reply with JSON only: {"bot":"<id>","reason":"<six words>"} or {"bot":null}.
        """
        return [
            .system(system),
            .user("Assistants:\n\(list)\n\nMessage:\n\(String(message.prefix(1_500)))"),
        ]
    }

    /// Pulls the first JSON object out of a reply that may be wrapped in prose or a code fence.
    public static func parse(_ reply: String, candidates: [BotProfile]) -> RouteDecision? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chosen = object["bot"] as? String
        else { return nil }
        let wanted = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = candidates.first(where: { $0.id == wanted })
            ?? candidates.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
        else { return nil }
        let reason = ((object["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RouteDecision(
            botId: match.id,
            botName: match.name,
            confidence: 0.8,
            reason: reason.isEmpty ? "chosen by the router model" : String(reason.prefix(120)),
            source: .model
        )
    }
}
