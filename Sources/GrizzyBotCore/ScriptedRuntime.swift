import Foundation

/// A side effect the store performs when a scripted reply is delivered.
public enum ScriptedAction: Sendable, Equatable {
    case takeover(reason: String)
    case spawnBot(name: String, title: String)
    case deleteBot(name: String)
    case subagent(task: String)
    case destinationWrite(title: String, body: String)
    case writeFile(path: String, content: String)
    case readFile(path: String)
    case editFile(path: String, content: String, append: Bool)
    case moveFile(from: String, to: String)
    case deleteFile(path: String)
    case listFiles(directory: String)
    case webSearch(query: String)
    case remember(text: String)
    case customTool(id: String, name: String)
    case mcpServer(id: String, name: String, prompt: String)
}

/// The deterministic reply a bot gives for a prompt.
public struct ScriptedReply: Sendable, Equatable {
    public var text: String
    public var action: ScriptedAction?

    public init(text: String, action: ScriptedAction? = nil) {
        self.text = text
        self.action = action
    }
}

/// Port of rakazo's `inferScript` plus OpenMausBot-style file + web tools.
public enum ScriptedRuntime {
    public static func reply(
        to prompt: String,
        customTools: [CustomAgentTool] = [],
        mcpServers: [McpServer] = []
    ) -> ScriptedReply {
        let lower = prompt.lowercased()

        if lower.contains("completed sign-in") || lower.contains("continue without requesting takeover") {
            return ScriptedReply(
                text: "signed in. the session stays in this computer — protected input never hit the thread."
            )
        }

        if lower.contains("take over") || lower.contains("sign in") || lower.contains("login") {
            return ScriptedReply(
                text: "i need you on the screen for a one-time sign-in. handing you the computer.",
                action: .takeover(reason: "Sign in to continue. Protected input stays off the thread.")
            )
        }

        if lower.contains("delete the bot named") || lower.contains("delete the child bot")
            || lower.contains("delete child") {
            let name = namedBot(prompt) ?? "Scout"
            return ScriptedReply(text: "removing that bot permanently.", action: .deleteBot(name: name))
        }

        if lower.contains("spawn a bot") || lower.contains("spawn a child")
            || lower.contains("create a bot named") || lower.contains("create a child bot") {
            let name = namedBot(prompt) ?? "Helper"
            return ScriptedReply(
                text: "creating a bot for that.",
                action: .spawnBot(name: name, title: "\(name) specialist")
            )
        }

        if lower.contains("subagent") || lower.contains("delegate to a helper") {
            return ScriptedReply(
                text: "spinning up a helper for that.",
                action: .subagent(task: prompt)
            )
        }

        if lower.contains("connector") || lower.contains("crm") || lower.contains("destination") {
            return ScriptedReply(
                text: "writing the record through the connected destination.",
                action: .destinationWrite(title: "GrizzyBot result", body: prompt)
            )
        }

        // Web search (OpenMausBot WebSearch tool)
        if lower.contains("search the web") || lower.contains("search online")
            || lower.contains("look up") || lower.hasPrefix("search for")
            || lower.contains("google ") || lower.contains("web search") {
            let query = extractSearchQuery(prompt)
            return ScriptedReply(
                text: "searching the web for that.",
                action: .webSearch(query: query)
            )
        }

        // File ops (rakazo write_file + home store)
        if (lower.contains("move file") || lower.contains("rename file") || lower.contains("move "))
            && (lower.contains(" to ") || lower.contains(" → ")) {
            if let (from, to) = extractMovePaths(prompt) {
                return ScriptedReply(
                    text: "moving that in my home.",
                    action: .moveFile(from: from, to: to)
                )
            }
        }

        if lower.contains("delete file") || lower.contains("remove file") {
            let path = extractPath(prompt) ?? "notes/result.txt"
            return ScriptedReply(
                text: "removing that file from my home.",
                action: .deleteFile(path: path)
            )
        }

        if lower.contains("list files") || lower.contains("list my files")
            || lower.contains("show files") || lower.contains("what's in my home") {
            let dir = extractPath(prompt) ?? ""
            return ScriptedReply(
                text: "listing files in my home.",
                action: .listFiles(directory: dir)
            )
        }

        if lower.contains("read file") || lower.contains("open file")
            || (lower.contains("read ") && lower.contains(".txt"))
            || (lower.contains("show me") && lower.contains("file")) {
            let path = extractPath(prompt) ?? "notes/result.txt"
            return ScriptedReply(
                text: "reading that from my home.",
                action: .readFile(path: path)
            )
        }

        if lower.contains("edit file") || lower.contains("append to")
            || (lower.contains("update") && lower.contains("file")) {
            let path = extractPath(prompt) ?? "notes/result.txt"
            let content = extractSaidContent(prompt) ?? prompt
            let append = lower.contains("append")
            return ScriptedReply(
                text: append ? "appending to that file." : "editing that file.",
                action: .editFile(path: path, content: content + (content.hasSuffix("\n") ? "" : "\n"), append: append)
            )
        }

        if lower.contains("write") && (lower.contains("file") || lower.contains("home") || lower.contains("note")) {
            let content = extractSaidContent(prompt) ?? prompt
            let path = extractPath(prompt) ?? "notes/result.txt"
            return ScriptedReply(
                text: "writing that into my home now.",
                action: .writeFile(path: path, content: content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            )
        }

        if lower.contains("remember") {
            return ScriptedReply(
                text: "noted — i will keep that in memory.",
                action: .remember(text: prompt)
            )
        }

        // MCP servers (name / "mcp <name>") — after builtins, before legacy custom tools.
        if let mcp = mcpServers.first(where: { $0.matches(prompt) }) {
            return ScriptedReply(
                text: mcp.renderResponse(prompt: prompt),
                action: .mcpServer(id: mcp.id, name: mcp.name, prompt: prompt)
            )
        }

        // Legacy phrase-match custom tools.
        if let custom = customTools.first(where: { $0.matches(prompt) }) {
            return ScriptedReply(
                text: custom.renderResponse(prompt: prompt),
                action: .customTool(id: custom.id, name: custom.name)
            )
        }

        return ScriptedReply(
            text: "on it. i will work this in the background and come back with a result.\n\n\(summarize(prompt))",
            action: .writeFile(path: "notes/last-task.md", content: "# Task\n\n\(prompt)\n")
        )
    }

    /// Result text a subagent reports when it finishes.
    public static func subagentResult(for task: String) -> String {
        "done. i handled: \(task.prefix(180))"
    }

    static func summarize(_ prompt: String) -> String {
        "done. i handled: \(prompt.prefix(180))"
    }

    static func namedBot(_ prompt: String) -> String? {
        let pattern = /named\s+(?<bot>[A-Za-z0-9][A-Za-z0-9_-]{0,39})/
        guard let match = prompt.firstMatch(of: pattern) else { return nil }
        return String(match.bot)
    }

    static func extractSearchQuery(_ prompt: String) -> String {
        let patterns: [Regex<(Substring, query: Substring)>] = [
            /(?i)search(?:\s+the\s+web|\s+online)?\s+for\s+(?<query>.+)/,
            /(?i)look\s+up\s+(?<query>.+)/,
            /(?i)web\s+search\s+(?<query>.+)/,
            /(?i)google\s+(?<query>.+)/,
        ]
        for pattern in patterns {
            if let match = prompt.firstMatch(of: pattern) {
                let chars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'."))
                return String(match.query).trimmingCharacters(in: chars)
            }
        }
        var cleaned = prompt
        for token in ["search the web", "search online", "web search", "look up", "google"] {
            if let range = cleaned.range(of: token, options: .caseInsensitive) {
                cleaned.removeSubrange(range)
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractPath(_ prompt: String) -> String? {
        let pattern = /(?<path>[\w.\-]+(?:\/[\w.\-]+)+\.\w{1,8}|[\w.\-]+\.\w{1,8})/
        if let match = prompt.firstMatch(of: pattern) {
            return String(match.path)
        }
        return nil
    }

    static func extractSaidContent(_ prompt: String) -> String? {
        let saidPattern = /[sS]ays?\s+(?<said>.+)$/
        if let match = prompt.firstMatch(of: saidPattern) {
            var captured = String(match.said)
            while let last = captured.last, last == "." { captured.removeLast() }
            return captured
        }
        if let range = prompt.range(of: "with \"") ?? prompt.range(of: "with '")
            ?? prompt.range(of: "with \"", options: .caseInsensitive)
            ?? prompt.range(of: "with '", options: .caseInsensitive) {
            var rest = String(prompt[range.upperBound...])
            if let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                rest = String(rest[..<end])
            }
            return rest
        }
        return nil
    }

    static func extractMovePaths(_ prompt: String) -> (String, String)? {
        let pattern = /(?i)(?<from>[\w.\-\/]+\.\w+)\s+(?:to|→|->)\s+(?<to>[\w.\-\/]+\.\w+)/
        if let match = prompt.firstMatch(of: pattern) {
            return (String(match.from), String(match.to))
        }
        return nil
    }
}
