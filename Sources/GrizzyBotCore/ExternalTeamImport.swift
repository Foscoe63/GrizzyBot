import Foundation

/// Reads team and bot files written for other tools and turns them into a `TeamPackage`, so they go
/// through the same review screen as a native team. Understands:
///  - OpenMausBot / BotMRR playbooks (`botmrr: 1|2` frontmatter with `agents`, `rooms`, `routines`)
///  - botteams listings (`bot_roster`, `routines`, `suggest` frontmatter)
/// Nothing is connected or switched on by the import; routines arrive paused like any other team.
public enum ExternalTeamImport {
    // MARK: Entry point

    public static func convert(markdown: String) -> TeamPackage? {
        guard let (front, body) = splitFrontmatter(markdown) else { return nil }
        var parser = MiniYAML(text: front)
        guard case .map(let root) = parser.parse() else { return nil }
        let package: TeamPackage?
        if root["agents"] != nil || root["botmrr"] != nil {
            package = fromOpenMaus(root, body: body)
        } else if root["bot_roster"] != nil {
            package = fromBotteams(root)
        } else {
            package = nil
        }
        guard var p = package, !p.bots.isEmpty else { return nil }
        if p.bots.count > TeamPackage.maxBots { p.bots = Array(p.bots.prefix(TeamPackage.maxBots)) }
        let kept = Set(p.bots.map(\.name))
        p.rooms = p.rooms.filter { Set($0.members).isSubset(of: kept) }
        p.routines = p.routines.filter { kept.contains($0.bot) }
        return p
    }

    static let maxInstructionChars = 8000
    private static let baseTools = ["read_file", "list_files", "web_search", "remember", "search_memory"]

    // MARK: OpenMausBot / BotMRR

    private static func fromOpenMaus(_ root: [String: MiniYAML.Node], body: String) -> TeamPackage? {
        guard let name = root["name"]?.string, !name.isEmpty else { return nil }
        let summary = root["summary"]?.string ?? root["tagline"]?.string ?? ""
        let chiefKey = root["chiefOfStaff"]?.string
        var playbooks: [String: (name: String, text: String)] = [:]
        for pb in root["playbooks"]?.items ?? [] {
            guard let key = pb["key"]?.string else { continue }
            playbooks[key] = (pb["name"]?.string ?? key, pb["instructions"]?.string ?? "")
        }
        var rules: [String: [String]] = [:]   // agent key → room rules
        for room in root["rooms"]?.items ?? [] {
            guard let bulletin = room["bulletin"]?.string, !bulletin.isEmpty else { continue }
            for m in room["members"]?.strings ?? [] { rules[m, default: []].append("In \(room["name"]?.string ?? "the room"): \(bulletin)") }
        }

        var keyToName: [String: String] = [:]
        var bots: [TeamPackage.BotSpec] = []
        var agents = root["agents"]?.items ?? []
        if agents.isEmpty {   // bot.md: one bot described by the file itself
            agents = [.map(root)]
        }
        for agent in agents {
            guard let botName = agent["name"]?.string, !botName.isEmpty else { continue }
            let key = agent["key"]?.string ?? botName
            keyToName[key] = botName
            let description = agent["description"]?.string ?? summary
            var parts = [description]
            let pbs = (agent["playbooks"]?.strings ?? []).compactMap { playbooks[$0] }
            if !pbs.isEmpty {
                parts.append("Playbooks you follow when a request matches:")
                for pb in pbs { parts.append("### \(pb.name)\n\(pb.text)") }
            }
            if let r = rules[key], !r.isEmpty { parts.append("Team rules:\n" + r.map { "- \($0)" }.joined(separator: "\n")) }
            if agents.count == 1, root["agents"] == nil, !body.isEmpty { parts.append(body) }
            let isChief = key == chiefKey
            bots.append(.init(
                name: botName, title: agent["title"]?.string ?? "",
                description: String(description.prefix(300)),
                instructions: clip(parts.filter { !$0.isEmpty }.joined(separator: "\n\n")),
                tools: baseTools + (isChief ? ["message_bot"] : []), chiefOfStaff: isChief
            ))
        }

        let rooms: [TeamPackage.RoomSpec] = (root["rooms"]?.items ?? []).compactMap { room in
            guard let n = room["name"]?.string else { return nil }
            return .init(name: n, members: (room["members"]?.strings ?? []).compactMap { keyToName[$0] })
        }
        let routines: [TeamPackage.RoutineSpec] = (root["routines"]?.items ?? []).compactMap { r in
            guard let owner = r["agent"]?.string.flatMap({ keyToName[$0] }) ?? bots.first?.name,
                  let n = r["name"]?.string, let prompt = r["prompt"]?.string else { return nil }
            return .init(bot: owner, name: n, prompt: clip(prompt), cron: cron(fromSchedule: r["schedule"]))
        }
        let connectors: [TeamPackage.ConnectorSpec] = (root["requirements"]?["apps"]?.items ?? []).compactMap { app in
            guard let slug = app["slug"]?.string else { return nil }
            return .init(slug: slug, name: app["label"]?.string ?? slug, why: app["reason"]?.string ?? "",
                         required: app["optional"]?.string != "true")
        }
        return TeamPackage(
            name: name, summary: summary, bots: bots, rooms: rooms, routines: routines, connectors: connectors,
            departments: bots.count > 1 ? [.init(name: name, bots: bots.map(\.name), rooms: rooms.map(\.name))] : []
        )
    }

    // MARK: botteams

    private static func fromBotteams(_ root: [String: MiniYAML.Node]) -> TeamPackage? {
        guard let name = root["name"]?.string, !name.isEmpty else { return nil }
        let summary = root["tagline"]?.string ?? ""
        let rules = (root["suggest"]?.items ?? []).compactMap { s -> String? in
            s["on"]?.string == "false" ? nil : s["text"]?.string
        }
        let bots: [TeamPackage.BotSpec] = (root["bot_roster"]?.items ?? []).compactMap { b in
            guard let n = b["name"]?.string, !n.isEmpty else { return nil }
            let persona = b["persona"]?.string ?? ""
            var text = persona
            if !rules.isEmpty { text += "\n\nRules:\n" + rules.map { "- \($0)" }.joined(separator: "\n") }
            return .init(name: n, title: root["section"]?.string ?? "", description: String(persona.prefix(300)),
                         instructions: clip(text), tools: baseTools)
        }
        let rooms: [TeamPackage.RoomSpec] = (root["rooms"]?.items ?? []).compactMap { r in
            guard let n = r["name"]?.string else { return nil }
            return .init(name: n, members: r["members"]?.strings ?? [])
        }
        let routines: [TeamPackage.RoutineSpec] = (root["routines"]?.items ?? []).compactMap { r in
            guard let owner = r["owner"]?.string ?? bots.first?.name, let n = r["name"]?.string,
                  let prompt = r["prompt"]?.string else { return nil }
            return .init(bot: owner, name: n, prompt: clip(prompt), cron: cron(fromSchedule: r["schedule"]))
        }
        let connectors = (root["connectors"]?.strings ?? []).map {
            TeamPackage.ConnectorSpec(slug: $0.lowercased().replacingOccurrences(of: " ", with: ""), name: $0)
        }
        let dept = root["section"]?.string ?? ""
        return TeamPackage(
            name: name, summary: summary, bots: bots, rooms: rooms, routines: routines, connectors: connectors,
            departments: bots.count > 1 && !dept.isEmpty ? [.init(name: dept, bots: bots.map(\.name), rooms: rooms.map(\.name))] : []
        )
    }

    // MARK: Schedules

    /// Best-effort cron. An empty string means "on events" (no schedule), which is always safe.
    static func cron(fromSchedule node: MiniYAML.Node?) -> String {
        guard let node else { return "" }
        if let text = node.string { return cron(fromText: text) }
        let time = hourMinute(node["time"]?.string ?? "") ?? (9, 0)
        let days = (node["weekdays"]?.strings ?? []).compactMap(Int.init).map { $0 == 7 ? 0 : $0 }
        let dow = days.isEmpty ? "*" : days.sorted().map(String.init).joined(separator: ",")
        switch node["type"]?.string?.lowercased() {
        case "hourly": return "0 * * * *"
        case "daily", "weekly", "weekdays": return "\(time.1) \(time.0) * * \(dow)"
        default: return ""
        }
    }

    public static func cron(fromText raw: String) -> String {
        let t = raw.lowercased()
        let hasCron = raw.split(separator: " ").count == 5 && raw.allSatisfy { "0123456789*/,- ".contains($0) }
        if hasCron { return raw }
        if t.contains("every hour") || t.hasPrefix("hourly") { return "0 * * * *" }
        let (h, m) = hourMinute(t) ?? (9, 0)
        let days = ["sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3, "thursday": 4, "friday": 5, "saturday": 6]
        if t.contains("weekday") { return "\(m) \(h) * * 1-5" }
        if let d = days.first(where: { t.contains($0.key) }) { return "\(m) \(h) * * \(d.value)" }
        if t.contains("every day") || t.contains("daily") { return "\(m) \(h) * * *" }
        return ""
    }

    private static func hourMinute(_ s: String) -> (Int, Int)? {
        guard let r = s.range(of: #"(\d{1,2}):(\d{2})\s*(am|pm)?"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let parts = s[r].lowercased().split(whereSeparator: { ": ".contains($0) })
        guard parts.count >= 2, var h = Int(parts[0]), let m = Int(parts[1].prefix(2)), h < 25, m < 60 else { return nil }
        if s[r].lowercased().hasSuffix("pm"), h < 12 { h += 12 }
        if s[r].lowercased().hasSuffix("am"), h == 12 { h = 0 }
        return (h % 24, m)
    }

    // MARK: Helpers

    private static func clip(_ s: String) -> String {
        s.count > maxInstructionChars ? String(s.prefix(maxInstructionChars)) : s
    }

    static func splitFrontmatter(_ text: String) -> (String, String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }
}

// MARK: - A small YAML reader

/// Just enough YAML for frontmatter: nested maps, lists, quoted and plain scalars, inline `[a, b]`
/// lists, and `|` / `>` block text. Anchors, tags and multi-document files are not supported.
struct MiniYAML {
    indirect enum Node {
        case scalar(String)
        case list([Node])
        case map([String: Node])

        var string: String? { if case .scalar(let s) = self { return s }; return nil }
        var items: [Node] { if case .list(let l) = self { return l }; return [] }
        var strings: [String] { items.compactMap(\.string) }
        subscript(key: String) -> Node? { if case .map(let m) = self { return m[key] }; return nil }
    }

    private struct Line { var indent: Int; var text: String }
    private var lines: [Line] = []
    private var pos = 0

    init(text: String) {
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: trimmed))
        }
    }

    mutating func parse() -> Node? {
        guard !lines.isEmpty else { return nil }
        return block(indent: lines[0].indent)
    }

    private mutating func block(indent: Int) -> Node {
        if lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") { return list(indent: indent) }
        return map(indent: indent)
    }

    private mutating func list(indent: Int) -> Node {
        var out: [Node] = []
        while pos < lines.count, lines[pos].indent == indent, lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") {
            let rest = String(lines[pos].text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent { out.append(block(indent: lines[pos].indent)) }
            } else if Self.splitKey(rest) != nil {
                // "- key: value": the item is a map whose first line is this one, shifted past the dash.
                let offset = lines[pos].text.count - rest.count
                lines[pos] = Line(indent: indent + offset, text: rest)
                out.append(map(indent: indent + offset))
            } else {
                out.append(.scalar(Self.scalar(rest)))
                pos += 1
            }
        }
        return .list(out)
    }

    private mutating func map(indent: Int) -> Node {
        var out: [String: Node] = [:]
        while pos < lines.count, lines[pos].indent == indent, let (key, value) = Self.splitKey(lines[pos].text) {
            pos += 1
            if value == "|" || value == ">" || value.hasPrefix("|-") || value.hasPrefix(">-") {
                var parts: [String] = []
                while pos < lines.count, lines[pos].indent > indent { parts.append(lines[pos].text); pos += 1 }
                out[key] = .scalar(parts.joined(separator: value.hasPrefix("|") ? "\n" : " "))
            } else if value.isEmpty {
                if pos < lines.count, lines[pos].indent > indent {
                    out[key] = block(indent: lines[pos].indent)
                } else if pos < lines.count, lines[pos].indent == indent, lines[pos].text.hasPrefix("- ") {
                    out[key] = list(indent: indent)   // "key:" followed by a list at the same indent
                } else {
                    out[key] = .scalar("")
                }
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                let inner = value.dropFirst().dropLast()
                out[key] = .list(inner.split(separator: ",").map { .scalar(Self.scalar(String($0).trimmingCharacters(in: .whitespaces))) }
                    .filter { $0.string?.isEmpty == false })
            } else {
                out[key] = .scalar(Self.scalar(value))
            }
        }
        // Skip a stray over-indented line rather than looping forever.
        if pos < lines.count, lines[pos].indent > indent, out.isEmpty { pos += 1 }
        return .map(out)
    }

    /// Splits `key: value` at the first colon that ends a key (not inside quotes, not part of a URL).
    private static func splitKey(_ text: String) -> (String, String)? {
        guard let first = text.first, first != "\"", first != "'", first != "[", first != "{" else { return nil }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == ":" {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<i]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, next == text.endIndex ? "" : String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func scalar(_ raw: String) -> String {
        var s = raw
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            let quote = s.first!
            s = String(s.dropFirst().dropLast())
            if quote == "\"" { s = s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n") }
        } else if let hash = s.range(of: " #") {
            s = String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}

// MARK: - GitHub links

/// Turns GitHub page links into the raw file or the list of teams they point at, so a person can
/// paste `github.com/owner/repo` or a file's page instead of hunting for the raw address.
public enum GitHubSource {
    struct Ref { var owner: String; var repo: String; var branch: String?; var path: String; var isFile: Bool }

    static func parse(_ url: URL) -> Ref? {
        guard url.scheme?.lowercased() == "https", ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let p = url.pathComponents.filter { $0 != "/" }
        guard p.count >= 2 else { return nil }
        let repo = p[1].hasSuffix(".git") ? String(p[1].dropLast(4)) : p[1]
        if p.count >= 5, p[2] == "blob" { return Ref(owner: p[0], repo: repo, branch: p[3], path: p[4...].joined(separator: "/"), isFile: true) }
        if p.count >= 4, p[2] == "tree" { return Ref(owner: p[0], repo: repo, branch: p[3], path: p.dropFirst(4).joined(separator: "/"), isFile: false) }
        guard p.count == 2 else { return nil }
        return Ref(owner: p[0], repo: repo, branch: nil, path: "", isFile: false)
    }

    /// A single-file page link becomes its raw address; everything else is returned unchanged.
    public static func rawURL(for url: URL) -> URL {
        guard let r = parse(url), r.isFile, let branch = r.branch else { return url }
        return URL(string: "https://raw.githubusercontent.com/\(r.owner)/\(r.repo)/\(branch)/\(r.path)") ?? url
    }

    public static func isRepoLink(_ url: URL) -> Bool { parse(url).map { !$0.isFile } ?? false }

    private struct Item: Decodable { var name: String; var type: String; var download_url: String? }

    private static let teamFolders = ["packages", "bots", "teams"]

    /// Lists the team files in a repository (or one folder of it) as a library.
    public static func index(for url: URL, session: URLSession = .shared) async throws -> TeamLibraryIndex {
        guard let r = parse(url), !r.isFile else { throw TeamPackage.ParseError.invalid("not a GitHub repository link") }
        let folders = r.path.isEmpty ? teamFolders : [r.path]
        var entries: [TeamLibraryEntry] = []
        for folder in folders {
            var comps = URLComponents(string: "https://api.github.com/repos/\(r.owner)/\(r.repo)/contents/\(folder)")
            if let b = r.branch { comps?.queryItems = [URLQueryItem(name: "ref", value: b)] }
            guard let api = comps?.url, let text = try? await TeamPackage.download(url: api, session: session),
                  let items = try? JSONDecoder().decode([Item].self, from: Data(text.utf8)) else { continue }
            for item in items where item.type == "file" && item.name.lowercased().hasSuffix(".md") {
                let upper = item.name.uppercased()
                if ["README.MD", "CONTRIBUTING.MD", "LICENSE.MD"].contains(upper) { continue }
                guard let raw = item.download_url, raw.hasPrefix("https://raw.githubusercontent.com/") else { continue }
                let slug = String(item.name.dropLast(3))
                entries.append(.init(id: "\(folder)/\(slug)", name: slug.replacingOccurrences(of: "-", with: " ").capitalized, url: raw, tags: [r.repo]))
            }
            if !entries.isEmpty { break }   // the first folder that has teams wins
        }
        guard !entries.isEmpty else { throw TeamPackage.ParseError.invalid("no team files found in that repository") }
        return TeamLibraryIndex(teams: Array(entries.prefix(TeamLibraryIndex.maxEntries)))
    }
}
