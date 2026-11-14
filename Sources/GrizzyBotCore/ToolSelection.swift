import Foundation

/// A per-bot cut-down of the tools a model is shown. Small-context local models pay for every tool
/// schema on every turn; this lets a bot offer only what it needs.
///
/// Two independent controls:
///
/// * **Selectors** — an allow list and an exclude list. Exclude always wins.
/// * **Lean turns** — send only the tools a turn looks like it needs; the rest stay one
///   `capabilities_load` away.
///
/// Selector grammar (case-sensitive, one per line):
///
/// ```
/// read_file          one built-in tool
/// builtin:*          every built-in tool
/// mcp:*              every MCP tool
/// mcp:gmail:*        every tool on the server named gmail
/// mcp:gmail:send     one MCP tool
/// *                  everything
/// ```
///
/// The loop's own tools (`capabilities_*`, `todo`, `complete`, `clarify`) are never removed: a run
/// cannot finish without them.
public struct ToolSelection: Codable, Hashable, Sendable {
    /// When true only tools matching `allow` are offered; an empty allow list then means "no tools".
    public var allowOnly: Bool
    public var allow: [String]
    public var exclude: [String]
    /// Offer only the tools a turn looks like it needs (see `lean(...)`).
    public var lean: Bool

    public static let maxSelectors = 256
    public static let maxSelectorLength = 1_024
    /// How many tools a lean turn may add beyond the always-on ones.
    public static let leanBudget = 8

    public init(allowOnly: Bool = false, allow: [String] = [], exclude: [String] = [], lean: Bool = false) {
        self.allowOnly = allowOnly
        self.allow = allow
        self.exclude = exclude
        self.lean = lean
    }

    /// True when this changes nothing, so the bot can store `nil` instead.
    public var isDefault: Bool { !allowOnly && allow.isEmpty && exclude.isEmpty && !lean }

    // MARK: - Selector syntax

    public enum Selector: Equatable, Sendable {
        case everything
        case allBuiltin
        case builtin(String)
        case allMcp
        case mcpServer(String)
        case mcpTool(server: String, tool: String)
    }

    public static func parse(_ raw: String) -> Selector? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxSelectorLength else { return nil }
        if text == "*" { return .everything }
        if text == "builtin:*" { return .allBuiltin }
        if text == "mcp:*" { return .allMcp }
        if text.hasPrefix("mcp:") {
            let parts = text.dropFirst(4).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].contains("*") else { return nil }
            if parts[1] == "*" { return .mcpServer(parts[0]) }
            guard !parts[1].contains("*") else { return nil }
            return .mcpTool(server: parts[0], tool: parts[1])
        }
        // A plain built-in id: no wildcards, no colons.
        guard !text.contains("*"), !text.contains(":"), !text.contains(where: \.isWhitespace) else { return nil }
        return .builtin(text)
    }

    /// Splits a multi-line field into valid selectors and the lines that could not be read.
    public static func parseLines(_ text: String) -> (selectors: [String], invalid: [String]) {
        var good: [String] = []
        var bad: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if parse(trimmed) != nil {
                if !good.contains(trimmed) { good.append(trimmed) }
            } else {
                bad.append(trimmed)
            }
        }
        if good.count > maxSelectors {
            bad.append(contentsOf: good[maxSelectors...])
            good = Array(good[..<maxSelectors])
        }
        return (good, bad)
    }

    // MARK: - Matching

    /// What kind of tool a chat-visible name is.
    enum Kind: Equatable {
        case builtin(String)
        case mcp(server: String, tool: String)
        case other(String)
    }

    static func kind(of name: String, builtinIds: Set<String>) -> Kind {
        if builtinIds.contains(name) { return .builtin(name) }
        if let split = McpNativeNaming.split(name) { return .mcp(server: split.server, tool: split.tool) }
        return .other(name)
    }

    static func matches(_ selector: Selector, _ kind: Kind) -> Bool {
        switch (selector, kind) {
        case (.everything, _): return true
        case (.allBuiltin, .builtin): return true
        case (.builtin(let id), .builtin(let name)): return id == name
        case (.builtin(let id), .other(let name)): return id == name
        case (.allMcp, .mcp): return true
        case (.mcpServer(let server), .mcp(let s, _)): return server == s
        case (.mcpTool(let server, let tool), .mcp(let s, let t)): return server == s && tool == t
        default: return false
        }
    }

    private static func parsed(_ selectors: [String]) -> [Selector] {
        selectors.prefix(maxSelectors).compactMap(parse)
    }

    /// Would this selection offer `name`? Loop tools are always offered.
    public func permits(
        _ name: String,
        builtinIds: Set<String> = Set(AgentToolCatalog.builtinIds)
    ) -> Bool {
        if AgentToolCatalog.alwaysOnIds.contains(name) { return true }
        let kind = Self.kind(of: name, builtinIds: builtinIds)
        if Self.parsed(exclude).contains(where: { Self.matches($0, kind) }) { return false }
        if allowOnly {
            return Self.parsed(allow).contains { Self.matches($0, kind) }
        }
        return true
    }

    /// Selectors that match nothing the bot could ever have, so the editor can warn about typos.
    public func unknownSelectors(
        knownBuiltinIds: Set<String> = Set(AgentToolCatalog.builtinIds),
        knownMcpServers: Set<String> = []
    ) -> [String] {
        (allow + exclude).filter { raw in
            switch Self.parse(raw) {
            case .builtin(let id)?: return !knownBuiltinIds.contains(id)
            case .mcpServer(let server)?, .mcpTool(let server, _)?: return !knownMcpServers.contains(server)
            default: return false
            }
        }
    }

    // MARK: - Applying

    public struct Applied: Equatable, Sendable {
        /// Tools sent with the request.
        public var offered: [ChatTool]
        /// Tools the selection allows but this turn left out; `capabilities_load` can bring them back.
        public var deferred: [ChatTool]

        public static func == (a: Applied, b: Applied) -> Bool {
            a.offered.map(\.function.name) == b.offered.map(\.function.name)
                && a.deferred.map(\.function.name) == b.deferred.map(\.function.name)
        }
    }

    /// Filters `tools` through the selectors, then (in lean mode) down to what `prompt` looks like it needs.
    /// `usedToolNames` are tools earlier turns in this thread already called, which stay offered.
    public func apply(
        to tools: [ChatTool],
        prompt: String,
        usedToolNames: Set<String> = [],
        builtinIds: Set<String> = Set(AgentToolCatalog.builtinIds)
    ) -> Applied {
        let permitted = tools.filter { permits($0.function.name, builtinIds: builtinIds) }
        guard lean else { return Applied(offered: permitted, deferred: []) }

        let optional = permitted.filter { !AgentToolCatalog.alwaysOnIds.contains($0.function.name) }
        let ranked = Self.rank(optional, prompt: prompt)
        var keep = Set(ranked.prefix(Self.leanBudget).map(\.function.name))
        keep.formUnion(usedToolNames.intersection(Set(optional.map(\.function.name))))
        // Delegation tools travel together, and a tool that was just asked for by name always stays.
        if keep.contains("spawn_bot") || keep.contains("message_bot") {
            keep.formUnion(["check_bot", "list_delegations", "stop_bot"].filter { name in
                optional.contains { $0.function.name == name }
            })
        }
        let offered = permitted.filter {
            AgentToolCatalog.alwaysOnIds.contains($0.function.name) || keep.contains($0.function.name)
        }
        let deferred = permitted.filter { tool in
            !AgentToolCatalog.alwaysOnIds.contains(tool.function.name) && !keep.contains(tool.function.name)
        }
        return Applied(offered: offered, deferred: deferred)
    }

    /// Cheap lexical relevance: how many of the prompt's words appear in a tool's name or description,
    /// names counting more. No model call, so it adds nothing to the turn's latency.
    static func rank(_ tools: [ChatTool], prompt: String) -> [ChatTool] {
        let words = Set(tokens(prompt))
        guard !words.isEmpty else { return [] }
        let scored: [(tool: ChatTool, score: Double, index: Int)] = tools.enumerated().map { index, tool in
            let nameWords = Set(tokens(tool.function.name))
            let descWords = Set(tokens(tool.function.description))
            var score = 0.0
            for word in words {
                if nameWords.contains(word) { score += 3 }
                else if descWords.contains(word) { score += 1 }
            }
            return (tool, score, index)
        }
        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.tool)
    }

    static func tokens(_ text: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "with", "this", "that", "from", "into", "your", "you", "are", "can", "use",
            "all", "any", "not", "but", "will", "when", "then", "than", "have", "has", "was", "its", "per",
        ]
        let lowered = text.lowercased().replacingOccurrences(of: "_", with: " ")
        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
            .map(Self.stem)
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "es", "ed", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// One line for the system prompt when tools were held back this turn.
    public static func deferredNote(_ deferred: [ChatTool]) -> String? {
        let names = deferred.map(\.function.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(24).joined(separator: ", ")
        let more = names.count > 24 ? " and \(names.count - 24) more" : ""
        return "Tools held back this turn to save context: \(shown)\(more). If one is what you need, call capabilities_load with its name and it will be available on your next step."
    }
}
