import Foundation

/// A reusable, parameterised task: "weekly digest of {{topic}}". Stored as a Markdown file so a recipe
/// can be shared, versioned, and read by a person. Run with `/recipe name key=value`.
public struct Recipe: Sendable, Equatable, Identifiable {
    public struct Param: Sendable, Equatable {
        public var name: String
        public var label: String
        public var defaultValue: String?
        public var isRequired: Bool { defaultValue == nil }
    }

    public var id: String
    public var description: String
    public var params: [Param]
    public var body: String
    /// Tool ids the recipe cannot run without (`needs-tools: web_fetch, shell`).
    public var needsTools: [String]
    /// Saved secret names the recipe uses (`needs-secrets: GITHUB_TOKEN`).
    public var needsSecrets: [String]

    public init(id: String, description: String, params: [Param] = [], body: String, needsTools: [String] = [], needsSecrets: [String] = []) {
        self.id = id
        self.description = description
        self.params = params
        self.body = body
        self.needsTools = needsTools
        self.needsSecrets = needsSecrets
    }
}

public enum RecipeError: Error, LocalizedError, Equatable {
    case malformed(String)
    case missing([String])

    public var errorDescription: String? {
        switch self {
        case .malformed(let why): return "That recipe file isn't valid: \(why)"
        case .missing(let names): return "This recipe needs: \(names.joined(separator: ", "))."
        }
    }
}

public enum RecipeMarkdown {
    /// ```
    /// ---
    /// name: weekly-digest
    /// description: Summarise the week on a topic
    /// params:
    ///   - topic | Topic to cover | AI news
    ///   - audience | Who it's for
    /// ---
    /// Write a digest of {{topic}} for {{audience}}.
    /// ```
    /// A param with no third field is required.
    public static func parse(_ raw: String, fallbackId: String = "recipe") throws -> Recipe {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            throw RecipeError.malformed("missing the --- header")
        }
        let header = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
        var body = String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        var name = fallbackId
        var description = ""
        var params: [Recipe.Param] = []
        var needsTools: [String] = []
        var needsSecrets: [String] = []
        func list(_ raw: Substring) -> [String] {
            raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var inParams = false
        for line in header.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inParams, trimmed.hasPrefix("-") {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                let parts = item.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let key = parts.first, !key.isEmpty else { continue }
                params.append(.init(name: key, label: parts.count > 1 && !parts[1].isEmpty ? parts[1] : key, defaultValue: parts.count > 2 ? parts[2] : nil))
                continue
            }
            inParams = false
            if trimmed.hasPrefix("name:") { name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("description:") { description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("needs-tools:") { needsTools = list(trimmed.dropFirst(12)) }
            else if trimmed.hasPrefix("needs-secrets:") { needsSecrets = list(trimmed.dropFirst(14)) }
            else if trimmed.hasPrefix("params:") { inParams = true }
        }
        let id = SkillMarkdown.slug(name)
        guard !id.isEmpty else { throw RecipeError.malformed("it has no name") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecipeError.malformed("the body is empty") }
        return Recipe(id: id, description: description, params: params, body: body.trimmingCharacters(in: .whitespacesAndNewlines), needsTools: needsTools, needsSecrets: needsSecrets)
    }

    public static func render(_ recipe: Recipe) -> String {
        var lines = ["---", "name: \(recipe.id)", "description: \(recipe.description)"]
        if !recipe.needsTools.isEmpty { lines.append("needs-tools: " + recipe.needsTools.joined(separator: ", ")) }
        if !recipe.needsSecrets.isEmpty { lines.append("needs-secrets: " + recipe.needsSecrets.joined(separator: ", ")) }
        if !recipe.params.isEmpty {
            lines.append("params:")
            for p in recipe.params {
                var fields = [p.name, p.label]
                if let d = p.defaultValue { fields.append(d) }
                lines.append("  - " + fields.joined(separator: " | "))
            }
        }
        lines += ["---", "", recipe.body, ""]
        return lines.joined(separator: "\n")
    }

    /// `key=value key2="a longer value"` → dictionary.
    public static func parseArguments(_ raw: String) -> (name: String, values: [String: String]) {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard let name = tokens.first else { return ("", [:]) }
        var values: [String: String] = [:]
        for token in tokens.dropFirst() {
            if let eq = token.firstIndex(of: "="), eq != token.startIndex {
                values[String(token[..<eq])] = String(token[token.index(after: eq)...])
            }
        }
        return (SkillMarkdown.slug(name), values)
    }

    /// Fill the body. Defaults cover missing values; anything still missing is an error.
    public static func fill(_ recipe: Recipe, values: [String: String]) throws -> String {
        var resolved: [String: String] = [:]
        var missing: [String] = []
        for p in recipe.params {
            if let v = values[p.name], !v.isEmpty { resolved[p.name] = v }
            else if let d = p.defaultValue { resolved[p.name] = d }
            else { missing.append(p.name) }
        }
        guard missing.isEmpty else { throw RecipeError.missing(missing) }
        var out = recipe.body
        for (k, v) in resolved { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }
}

public enum RecipeLibrary {
    public static func directory(root: URL) -> URL { root.appendingPathComponent("recipes", isDirectory: true) }

    public static func load(root: URL) -> [Recipe] {
        let dir = directory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".md") }.compactMap { file in
            guard let raw = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return try? RecipeMarkdown.parse(raw, fallbackId: String(file.dropLast(3)))
        }
    }

    @discardableResult
    public static func save(_ recipe: Recipe, root: URL) throws -> URL {
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(SkillMarkdown.slug(recipe.id)).md")
        try RecipeMarkdown.render(recipe).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func delete(id: String, root: URL) {
        try? FileManager.default.removeItem(at: directory(root: root).appendingPathComponent("\(SkillMarkdown.slug(id)).md"))
    }

    /// Import a recipe file, refusing one whose body trips the skill scanner's danger rules.
    @discardableResult
    public static func importFile(_ file: URL, root: URL) throws -> Recipe {
        let raw = try String(contentsOf: file, encoding: .utf8)
        let recipe = try RecipeMarkdown.parse(raw, fallbackId: file.deletingPathExtension().lastPathComponent)
        let report = SkillScanner.scan(AgentSkill(id: recipe.id, name: recipe.id, description: recipe.description, body: recipe.body, source: .user))
        if report.risk == .danger { throw RecipeError.malformed("the scanner flagged it:\n\(report.summary)") }
        try save(recipe, root: root)
        return recipe
    }
}


/// Checks a recipe's declared needs against a bot before the run starts, so a missing tool or secret is
/// reported up front instead of half-way through.
public enum RecipeRequirements {
    public static func missing(_ recipe: Recipe, enabledTools: [String], secretNames: [String]) -> [String] {
        var out: [String] = []
        let tools = Set(enabledTools)
        let off = recipe.needsTools.filter { !tools.contains($0) }
        if !off.isEmpty { out.append("tool\(off.count == 1 ? "" : "s") switched off for this bot: " + off.joined(separator: ", ")) }
        let have = Set(secretNames.map { $0.uppercased() })
        let secrets = recipe.needsSecrets.filter { !have.contains($0.uppercased()) }
        if !secrets.isEmpty { out.append("no saved secret named " + secrets.joined(separator: ", ")) }
        return out
    }
}

/// A step-by-step record of what a run did: which tool, whether it worked, how long it took. Kept for
/// the most recent runs so a person (or a test) can see what actually happened.
public final class RunRecorder: @unchecked Sendable {
    public static let shared = RunRecorder()

    public struct Step: Sendable, Equatable {
        public var tool: String
        public var ok: Bool
        public var failureKind: String?
        public var milliseconds: Int
    }

    private let lock = NSLock()
    private var steps: [String: [Step]] = [:]
    private var order: [String] = []
    private let runCap = 50, stepCap = 200

    public init() {}

    public func record(run: String, tool: String, output: String, milliseconds: Int) {
        let failure = ToolEnvelope.classify(output: output)
        let step = Step(tool: tool, ok: failure == nil, failureKind: failure?.kind.rawValue, milliseconds: milliseconds)
        lock.lock(); defer { lock.unlock() }
        if steps[run] == nil {
            order.append(run)
            if order.count > runCap { steps[order.removeFirst()] = nil }
        }
        if (steps[run]?.count ?? 0) < stepCap { steps[run, default: []].append(step) }
    }

    public func steps(for run: String) -> [Step] {
        lock.lock(); defer { lock.unlock() }
        return steps[run] ?? []
    }

    public func summary(for run: String) -> String {
        let list = steps(for: run)
        guard !list.isEmpty else { return "No tool steps recorded for this run." }
        let failed = list.filter { !$0.ok }
        var lines = ["\(list.count) step\(list.count == 1 ? "" : "s"), \(failed.count) failed"]
        for (i, s) in list.enumerated() {
            lines.append("\(i + 1). \(s.tool) — \(s.ok ? "ok" : "failed (\(s.failureKind ?? "error"))") — \(s.milliseconds) ms")
        }
        return lines.joined(separator: "\n")
    }
}
