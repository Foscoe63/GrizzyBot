import Foundation

public enum SkillSource: String, Codable, Sendable {
    case bundled
    case user
}

/// Agent skill (holaOS / SKILL.md): short catalog line plus a full body loaded on demand.
public struct AgentSkill: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var body: String
    public var source: SkillSource
    public var allowedTools: [String]

    public init(
        id: String,
        name: String,
        description: String,
        body: String,
        source: SkillSource = .bundled,
        allowedTools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.body = body
        self.source = source
        self.allowedTools = allowedTools
    }

    public var catalogLine: String {
        "- \(id): \(description)"
    }
}

public enum SkillParseError: Error, LocalizedError, Sendable, Equatable {
    case missingFrontmatter
    case missingDescription

    public var errorDescription: String? {
        switch self {
        case .missingFrontmatter:
            return "SKILL.md must start with YAML frontmatter (--- ... ---)"
        case .missingDescription:
            return "SKILL.md frontmatter must include a non-empty description"
        }
    }
}

public enum SkillMarkdown {
    public static func parse(_ raw: String, fallbackId: String, source: SkillSource) throws -> AgentSkill {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("---") else {
            throw SkillParseError.missingFrontmatter
        }
        let afterOpen = normalized.dropFirst(3)
        guard let end = afterOpen.range(of: "\n---") else {
            throw SkillParseError.missingFrontmatter
        }
        let yaml = String(afterOpen[..<end.lowerBound])
        var body = String(afterOpen[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        let fields = parseSimpleYAML(yaml)
        let id = slug(fields["name"] ?? fallbackId)
        let description = (fields["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw SkillParseError.missingDescription }
        let name = fields["name"] ?? id
        let tools = parseList(fields["allowed-tools"] ?? fields["allowed_tools"] ?? "")
        return AgentSkill(
            id: id.isEmpty ? fallbackId : id,
            name: name,
            description: description,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            allowedTools: tools
        )
    }

    public static func render(_ skill: AgentSkill) -> String {
        var lines = [
            "---",
            "name: \(skill.id)",
            "description: \(skill.description)",
        ]
        if !skill.allowedTools.isEmpty {
            lines.append("allowed-tools: [\(skill.allowedTools.joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append(skill.body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func catalogPrompt(from skills: [AgentSkill], injected: [AgentSkill] = []) -> String {
        guard !skills.isEmpty else { return "" }
        var parts: [String] = []
        if !injected.isEmpty {
            parts.append("Matched skills for this turn (already loaded — follow them):")
            for skill in injected {
                parts.append("## \(skill.id)\n\(skill.description)\n\n\(skill.body)")
            }
        }
        let remaining = skills.filter { skill in !injected.contains(where: { $0.id == skill.id }) }
        if !remaining.isEmpty {
            let lines = remaining.map(\.catalogLine).joined(separator: "\n")
            parts.append(
                """
                Other skills (call read_skill with the id, then follow that skill):
                \(lines)
                """
            )
        }
        return parts.joined(separator: "\n\n")
    }

    /// Rank skills whose id, name, or description overlap the user prompt.
    public static func matching(_ skills: [AgentSkill], prompt: String, limit: Int = 2) -> [AgentSkill] {
        let tokens = Set(MemoryIndex.tokenize(prompt))
        guard !tokens.isEmpty else { return [] }
        let ranked: [(AgentSkill, Int)] = skills.compactMap { skill in
            let hay = MemoryIndex.tokenize("\(skill.id) \(skill.name) \(skill.description)")
            let score = hay.reduce(0) { $0 + (tokens.contains($1) ? 2 : 0) }
            let bodyHits = MemoryIndex.tokenize(String(skill.body.prefix(400)))
                .reduce(0) { $0 + (tokens.contains($1) ? 1 : 0) }
            let total = score + bodyHits
            return total > 0 ? (skill, total) : nil
        }
        return Array(ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    private static func parseSimpleYAML(_ yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingKey: String?
        var pendingItems: [String] = []
        func flushList() {
            guard let key = pendingKey else { return }
            result[key] = pendingItems.joined(separator: ", ")
            pendingKey = nil
            pendingItems = []
        }
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let item = line.range(of: #"^\s*-\s+"#, options: .regularExpression) {
                pendingItems.append(String(line[item.upperBound...]).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushList()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                pendingKey = key
                pendingItems = []
            } else {
                result[key] = unquote(value)
            }
        }
        flushList()
        return result
    }

    private static func parseList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let inner: String
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            inner = String(trimmed.dropFirst().dropLast())
        } else {
            inner = trimmed
        }
        return inner
            .split(separator: ",")
            .map { unquote(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    public static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }
}

public enum BundledSkills {
    public static var ids: [String] { all.map(\.id) }

    public static let all: [AgentSkill] = [
        research,
        browser,
        officeDocs,
        coding,
        memory,
        skillCreator,
    ]

    public static let research = AgentSkill(
        id: "research",
        name: "research",
        description: "Search the web, fetch sources, and write a cited brief.",
        body: """
        # Research

        Use when the user wants current facts, comparisons, or a sourced write-up.

        ## Workflow
        1. If the question is about GrizzyBot or this Mac (Settings, Keys, plugins, bots), answer from the system prompt and local files. Do not web-search for those labels.
        2. Otherwise call `web_search` once with a precise query. One follow-up is allowed only if results are thin but non-empty.
        3. `web_fetch` the 2–4 best URLs. Quote or paraphrase; do not invent citations.
        4. Write the answer with short bullets, then a **Sources** list of title + URL.
        5. If the user asked for a file, `write_file` a markdown brief under `notes/`.

        ## Rules
        - Prefer primary sources over aggregators.
        - If search fails, is blocked, or returns no results twice, stop. Say so and work from what you have (including this Mac Settings). Do not keep retrying similar queries.
        - Never claim you visited a page unless `web_fetch` returned it.
        """,
        allowedTools: ["web_search", "web_fetch", "write_file"]
    )

    public static let browser = AgentSkill(
        id: "browser",
        name: "browser",
        description: "Drive the live computer: open URLs, screenshot, click, type, take over.",
        body: """
        # Browser

        Use when the user wants you to operate a site or the desktop, not just fetch HTML.

        ## Workflow
        1. `computer_open` the URL (or a local `file://` path).
        2. `computer_screenshot` and read the image before clicking.
        3. `computer_click` / `computer_type` for the next action. Screenshot again after each important step.
        4. If a login, captcha, or 2FA appears, `request_takeover` and wait.

        ## Rules
        - Do not guess coordinates. Use the latest screenshot.
        - Prefer the computer tools over `web_fetch` when the page is interactive or behind a session.
        """,
        allowedTools: ["computer_open", "computer_screenshot", "computer_click", "computer_type", "request_takeover"]
    )

    public static let officeDocs = AgentSkill(
        id: "office-docs",
        name: "office-docs",
        description: "Produce real files: markdown reports, CSV spreadsheets, HTML slides.",
        body: """
        # Office documents

        Use when the user wants a report, spreadsheet, slide deck, or hand-off file — not just chat text.

        ## Outputs (write these with `write_file`)
        - Reports / papers: `notes/<slug>.md` with title, summary, body, and sources.
        - Spreadsheets: `notes/<slug>.csv` with a header row and consistent columns.
        - Slides: `notes/<slug>.html` — one section per slide, large headings, short bullets.
        - Outlines: `notes/<slug>-outline.md` if they asked for a deck but not a file type.

        ## Workflow
        1. Confirm the deliverable and filename in one line, then write the file.
        2. Keep tables CSV-safe (quote cells that contain commas).
        3. Tell the user the exact path so they can open it from Files.

        ## Rules
        - Do not claim you created .pptx/.docx/.xlsx unless that file actually exists in the bot home.
        - Prefer files the user can open on this Mac without extra software: md, csv, html, txt.
        """,
        allowedTools: ["write_file", "read_file", "list_files"]
    )

    public static let coding = AgentSkill(
        id: "coding",
        name: "coding",
        description: "Read, edit, and run code inside the bot home.",
        body: """
        # Coding

        Use when the user wants you to inspect or change files in your home, or run commands.

        ## Workflow
        1. `list_files` / `read_file` before editing. Do not invent file contents.
        2. Small changes: `edit_file`. New files: `write_file`.
        3. `shell` to run tests or scripts. cwd stays inside the bot home.
        4. Summarize what changed and how to run it.

        ## Rules
        - Stay inside the bot home. Do not ask to escape the sandbox.
        - If a command needs approval, wait for the user.
        """,
        allowedTools: ["read_file", "write_file", "edit_file", "list_files", "shell"]
    )

    public static let memory = AgentSkill(
        id: "memory",
        name: "memory",
        description: "Store durable facts on this bot or the shared workspace memory.",
        body: """
        # Memory

        Use when the user says remember, or when a preference/fact should survive this turn.

        ## Scope
        - `remember` with `scope: bot` (default): only this bot sees it (MEMORY.md).
        - `remember` with `scope: shared`: every bot on this Mac sees it (SHARED.md).

        ## What to store
        - Names, preferences, standing instructions, project facts.
        - Not secrets (API keys, passwords) unless the user explicitly asks.

        ## Rules
        - One fact per remember call. Phrase it as a standalone bullet.
        - Do not remember ephemeral task progress.
        """,
        allowedTools: ["remember"]
    )

    public static let skillCreator = AgentSkill(
        id: "skill-creator",
        name: "skill-creator",
        description: "Author a new SKILL.md the user can install for every bot.",
        body: """
        # Skill creator

        Use when the user wants a reusable workflow packaged as a skill.

        ## Format
        Write a SKILL.md:

        ```
        ---
        name: short-id
        description: one line, including when to use it
        ---

        # Title
        ## When to use
        ## Workflow
        ## Rules
        ```

        ## Rules
        - `name` is a slug; it must match the folder name under Application Support/GrizzyBot/skills/.
        - Description must be specific enough to pick this skill from a catalog.
        - Keep the body short. Point at tools that already exist (write_file, web_search, shell, …).
        - After drafting, tell the user they can paste it into Skills → New skill.
        """,
        allowedTools: ["write_file"]
    )
}

public enum SkillLibrary {
    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("skills", isDirectory: true)
    }

    public static func load(root: URL) -> [AgentSkill] {
        BundledSkills.all + loadUserSkills(root: root)
    }

    public static func loadUserSkills(root: URL) -> [AgentSkill] {
        let dir = directory(root: root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            let file = dir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return try? SkillMarkdown.parse(raw, fallbackId: name, source: .user)
        }
    }

    public static func saveUserSkill(_ skill: AgentSkill, root: URL) throws {
        let id = SkillMarkdown.slug(skill.id)
        let folder = directory(root: root).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored = skill
        stored.id = id
        stored.source = .user
        try SkillMarkdown.render(stored).write(
            to: folder.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Copy every SKILL.md under `folder` into the workspace skill library.
    @discardableResult
    public static func importFromDirectory(_ folder: URL, into root: URL, limit: Int = 40) throws -> [AgentSkill] {
        var imported: [AgentSkill] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            throw BotHomeError.notFound(folder.path)
        }
        var files: [URL] = []
        if isDir.boolValue {
            if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in enumerator {
                    if url.lastPathComponent == "SKILL.md" { files.append(url) }
                }
            }
        } else if folder.lastPathComponent == "SKILL.md" {
            files.append(folder)
        }
        for url in files.prefix(limit) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallback = url.deletingLastPathComponent().lastPathComponent
            guard let skill = try? SkillMarkdown.parse(raw, fallbackId: fallback, source: .user) else { continue }
            try saveUserSkill(skill, root: root)
            imported.append(skill)
        }
        return imported
    }

    public static func deleteUserSkill(id: String, root: URL) throws {
        let folder = directory(root: root).appendingPathComponent(SkillMarkdown.slug(id), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}
