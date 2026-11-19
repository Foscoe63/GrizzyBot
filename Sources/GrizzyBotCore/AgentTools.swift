import Foundation

public enum AgentToolKind: String, Codable, Sendable, Hashable {
    case builtin
    case custom
    case mcp
}

/// Catalog entry for a tool a bot may use (builtin, custom, or MCP server).
public struct AgentToolDefinition: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var subtitle: String
    public var kind: AgentToolKind

    public var isBuiltin: Bool { kind == .builtin }

    public init(
        id: String,
        label: String,
        subtitle: String,
        kind: AgentToolKind = .builtin
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.kind = kind
    }

    public init(id: String, label: String, subtitle: String, isBuiltin: Bool) {
        self.init(id: id, label: label, subtitle: subtitle, kind: isBuiltin ? .builtin : .custom)
    }
}

public enum McpTransport: String, Codable, Sendable, CaseIterable, Identifiable, CustomStringConvertible {
    case stdio
    case http
    case sse

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .stdio: return "Stdio (command)"
        case .http: return "Streamable HTTP"
        case .sse: return "HTTP + SSE (legacy)"
        }
    }
}

/// User-configured MCP server (Cursor-style). Exposed as a toggleable tool for bots.
public struct McpServer: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var transport: McpTransport
    /// Stdio: executable to launch.
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// HTTP/SSE: endpoint URL.
    public var url: String
    public var headers: [String: String]
    public var createdAt: Date

    public init(
        id: String = Ids.new(),
        name: String,
        transport: McpTransport = .stdio,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        url: String = "",
        headers: [String: String] = [:],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.createdAt = createdAt
    }

    /// Stable tool id used in `enabledTools` / defaults.
    public var toolId: String { "mcp:\(id)" }

    public var definition: AgentToolDefinition {
        let detail: String
        switch transport {
        case .stdio:
            let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let argPart = args.isEmpty ? "" : " " + args.joined(separator: " ")
            detail = cmd.isEmpty ? "MCP · stdio" : "MCP · \(cmd)\(argPart)"
        case .http:
            let endpoint = url.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = endpoint.isEmpty ? "MCP · HTTP" : "MCP · \(endpoint)"
        case .sse:
            let endpoint = url.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = endpoint.isEmpty ? "MCP · SSE" : "MCP · SSE · \(endpoint)"
        }
        return AgentToolDefinition(
            id: toolId,
            label: name,
            subtitle: detail,
            kind: .mcp
        )
    }

    public func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty else { return false }
        if lower.contains("mcp \(n)") || lower.contains("mcp:\(n)") { return true }
        return lower.contains(n)
    }

    public func renderResponse(prompt: String) -> String {
        switch transport {
        case .stdio:
            let cmd = ([command] + args).filter { !$0.isEmpty }.joined(separator: " ")
            return "calling MCP server **\(name)** via stdio (`\(cmd.isEmpty ? "…" : cmd)`)…"
        case .http:
            let endpoint = url.isEmpty ? "…" : url
            return "calling MCP server **\(name)** over streamable HTTP (\(endpoint))…"
        case .sse:
            let endpoint = url.isEmpty ? "…" : url
            return "calling MCP server **\(name)** over HTTP+SSE (\(endpoint))…"
        }
    }

    public var summaryLine: String {
        switch transport {
        case .stdio:
            let cmd = ([command] + args).filter { !$0.isEmpty }.joined(separator: " ")
            return cmd.isEmpty ? "stdio" : cmd
        case .http:
            return url.isEmpty ? "http" : url
        case .sse:
            return url.isEmpty ? "sse" : url
        }
    }
}

/// `fast-filesystem-mcp` ignores positional paths. Official `server-filesystem` uses them.
/// Rewrite leftover absolute paths as `--allow` so Settings args actually take effect.
public enum FastFilesystemMcpArgs {
    private static let valueFlags: Set<String> = ["--allow", "--disable-tools", "-dt"]

    public static func matches(command: String, args: [String]) -> Bool {
        ([command] + args).joined(separator: " ").lowercased().contains("fast-filesystem-mcp")
    }

    public static func normalize(command: String, args: [String]) -> [String] {
        guard matches(command: command, args: args) else { return args }
        var out: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            if Self.valueFlags.contains(token), i + 1 < args.count {
                out.append(token)
                out.append(args[i + 1])
                i += 2
                continue
            }
            if isAllowPath(token) {
                out.append("--allow")
                out.append(token)
                i += 1
                continue
            }
            out.append(token)
            i += 1
        }
        return out
    }

    private static func isAllowPath(_ token: String) -> Bool {
        token.hasPrefix("/") || token.hasPrefix("~/")
    }
}

/// Text form helpers for the MCP server editor (env/headers/args).
public enum McpConfigText {
    public static func parseEnv(_ text: String) -> [String: String] {
        parseKeyedLines(text, separator: "=")
    }

    public static func parseHeaders(_ text: String) -> [String: String] {
        parseKeyedLines(text, separator: ":")
    }

    public static func envLines(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }

    public static func headerLines(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    /// Shell-style split: whitespace separates args, single/double quotes group words
    /// (so `--header "Authorization: Bearer x"` stays one arg), backslash escapes outside single quotes.
    public static func parseArgs(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inArg = false
        var quote: Character?
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && quote != "'" {
                escaped = true
                inArg = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inArg = true
            } else if ch.isWhitespace {
                if inArg { args.append(current) }
                current = ""
                inArg = false
            } else {
                current.append(ch)
                inArg = true
            }
        }
        if inArg { args.append(current) }
        return args
    }

    public static func argsLine(_ args: [String]) -> String {
        args.map { arg in
            guard arg.isEmpty || arg.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return arg }
            let escaped = arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    private static func parseKeyedLines(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let idx = trimmed.firstIndex(of: separator) else { continue }
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

/// Legacy phrase-match tool (still loaded if present). Prefer `McpServer` for new tools.
public struct CustomAgentTool: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    /// Case-insensitive substrings that activate this tool in a prompt.
    public var triggers: [String]
    /// Reply template; `{prompt}` is replaced with the user message.
    public var responseTemplate: String
    public var createdAt: Date

    public init(
        id: String = Ids.new(),
        name: String,
        description: String = "",
        triggers: [String] = [],
        responseTemplate: String = "ran **{name}** on: {prompt}",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.triggers = triggers
        self.responseTemplate = responseTemplate
        self.createdAt = createdAt
    }

    public var definition: AgentToolDefinition {
        AgentToolDefinition(
            id: id,
            label: name,
            subtitle: description.isEmpty ? "Custom tool" : description,
            kind: .custom
        )
    }

    public func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return triggers.contains { trigger in
            let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && lower.contains(t.lowercased())
        }
    }

    public func renderResponse(prompt: String) -> String {
        responseTemplate
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{prompt}", with: prompt)
            .replacingOccurrences(of: "{description}", with: description)
    }
}

public enum AgentToolCatalog {
    public static let builtin: [AgentToolDefinition] = [
        .init(id: "write_file", label: "Write file", subtitle: "Write the working folder when set, otherwise bot home"),
        .init(id: "read_file", label: "Read file", subtitle: "Read the working folder, bot home, or approved host paths"),
        .init(id: "edit_file", label: "Edit file", subtitle: "Replace or append file contents"),
        .init(id: "move_file", label: "Move / rename file", subtitle: "Move files in the working folder or bot home"),
        .init(id: "delete_file", label: "Delete file", subtitle: "Remove files from the working folder or bot home"),
        .init(id: "list_files", label: "List files", subtitle: "List the working folder when set, otherwise bot home"),
        .init(id: "web_search", label: "Web search", subtitle: "Search the internet and fetch pages"),
        .init(id: "shell", label: "Shell", subtitle: "Run shell commands in the bot home"),
        .init(id: "shortcuts_list", label: "List shortcuts", subtitle: "See the Shortcuts in your library"),
        .init(id: "shortcuts_run", label: "Run shortcut", subtitle: "Run one of your Shortcuts by name"),
        .init(id: "remember", label: "Remember", subtitle: "Store durable memory facts"),
        .init(id: "search_memory", label: "Search memory", subtitle: "Retrieve facts from bot and shared memory"),
        .init(id: "forget", label: "Forget", subtitle: "Remove a durable memory fact"),
        .init(id: "request_takeover", label: "Request takeover", subtitle: "Hand the computer to you for sign-in"),
        .init(id: "request_secret", label: "Request secret", subtitle: "Ask you for a key or password without seeing it"),
        .init(id: "spawn_bot", label: "Spawn bot", subtitle: "Create a child bot"),
        .init(id: "message_bot", label: "Message bot", subtitle: "Hand a task to another bot in the workspace"),
        .init(id: "delete_bot", label: "Delete bot", subtitle: "Permanently remove a spawned bot"),
        .init(id: "run_subagent", label: "Run subagent", subtitle: "Delegate to a short-lived helper"),
        .init(id: "delegate_external", label: "External coding agent", subtitle: "Hand a coding job to opencode in the working folder"),
        .init(id: "destination_write", label: "Destination write", subtitle: "Write through connected destinations"),
        .init(id: "computer_screenshot", label: "Screenshot", subtitle: "Capture the live computer screen"),
        .init(id: "computer_open", label: "Open URL", subtitle: "Open a URL on the computer"),
        .init(id: "computer_click", label: "Click", subtitle: "Click on the computer screen"),
        .init(id: "computer_type", label: "Type", subtitle: "Type into the computer"),
        .init(id: "computer_key", label: "Key", subtitle: "Press a key on the computer"),
        .init(id: "computer_scroll", label: "Scroll", subtitle: "Scroll the computer screen"),
        .init(id: "plugin_call", label: "Plugin call", subtitle: "Search or write through a connected plugin"),
        .init(id: "read_skill", label: "Read skill", subtitle: "Load a skill's full instructions"),
        .init(id: "import_skills", label: "Import skills", subtitle: "Copy SKILL.md folders into GrizzyBot"),
        .init(id: "skill_propose", label: "Propose skill", subtitle: "Draft a reusable skill for you to review"),
        .init(id: "routine_manage", label: "Routines", subtitle: "Create, list, pause, or delete this bot's scheduled routines"),
        .init(id: "config_manage", label: "App settings", subtitle: "Change a few safe app settings for you, after you approve each change"),
        .init(id: "workflow_run", label: "Workflows", subtitle: "Run saved multi-step workflows"),
        .init(id: "generate_image", label: "Make images", subtitle: "Create pictures on this Mac with Apple Image Playground"),
        .init(id: "search_knowledge", label: "Search knowledge", subtitle: "Search granted knowledge sources"),
        .init(id: "search_sessions", label: "Search past chats", subtitle: "Find things said in this bot's earlier conversations"),
        .init(id: "present_component", label: "Present component", subtitle: "Show a form, gallery, or audit component"),
        .init(id: "report_decline", label: "Report decline", subtitle: "Audit that this bot declined a request"),
        .init(id: "canvas_list", label: "Canvas list", subtitle: "List shared canvases on this Mac"),
        .init(id: "canvas_open", label: "Canvas open", subtitle: "Open a shared canvas in the editor"),
        .init(id: "canvas_save", label: "Canvas save", subtitle: "Create or update a shared canvas"),
        .init(id: "canvas_delete", label: "Canvas delete", subtitle: "Delete a shared canvas"),
        .init(id: "canvas_place_image", label: "Canvas place image", subtitle: "Drop a screenshot or image onto a canvas"),
        .init(id: "artifact_create", label: "Artifact create", subtitle: "Create a shared artifact"),
        .init(id: "artifact_update", label: "Artifact update", subtitle: "Edit part of an artifact"),
        .init(id: "artifact_rewrite", label: "Artifact rewrite", subtitle: "Replace an artifact's contents"),
        .init(id: "artifact_list", label: "Artifact list", subtitle: "List shared artifacts on this Mac"),
        .init(id: "artifact_read", label: "Artifact read", subtitle: "Read an artifact's contents"),
        .init(id: "artifact_delete", label: "Artifact delete", subtitle: "Delete a shared artifact"),
        .init(id: "meeting_notes", label: "Meeting notes", subtitle: "Turn a transcript into a summary, decisions and action items"),
        .init(id: "capabilities_discover", label: "Discover capabilities", subtitle: "Search skills and MCP tools on demand"),
        .init(id: "capabilities_load", label: "Load capabilities", subtitle: "Activate discovered skills or MCP tools"),
        .init(id: "todo", label: "Todo", subtitle: "Write a multi-step checklist for this turn"),
        .init(id: "complete", label: "Complete", subtitle: "Finish the task with a short summary"),
        .init(id: "clarify", label: "Clarify", subtitle: "Pause and ask the user a question"),
        .init(id: "propose_team_memory", label: "Propose team note", subtitle: "Suggest a fact for the department's shared memory (you approve it)"),
        .init(id: "search_team_memory", label: "Search team notes", subtitle: "Look up the department's shared notes"),
    ]

    /// Always available, whatever is toggled: the loop cannot work without them, so they get no switch.
    public static let alwaysOnIds: Set<String> = ["capabilities_discover", "capabilities_load", "todo", "complete", "clarify", "propose_team_memory", "search_team_memory"]

    /// Tools that have no switch in the profile editor.
    public static var unswitchedIds: Set<String> {
        alwaysOnIds.union(CanvasBoardStore.toolIds).union(ArtifactStore.toolIds)
    }

    /// What used to switch on silently when another tool was on. Written out once as real toggles
    /// (see `AppStore.grantImpliedTools`) so each can be turned off on its own.
    public static func impliedGrants(from enabled: [String]) -> [String] {
        var set = Set(enabled)
        var changed = true
        while changed {
            changed = false
            func grant(_ ids: [String], if condition: Bool) {
                guard condition else { return }
                for id in ids where !set.contains(id) { set.insert(id); changed = true }
            }
            grant(["import_skills", "skill_propose"], if: set.contains("read_file"))
            grant(["routine_manage"], if: set.contains("shell") || set.contains("spawn_bot") || set.contains("message_bot"))
            grant(["request_secret"], if: set.contains("request_takeover") || set.contains("plugin_call"))
            grant(["search_memory", "forget"], if: set.contains("remember"))
            grant(["search_knowledge", "search_sessions"], if: set.contains("remember") || set.contains("search_memory"))
            grant(["message_bot"], if: set.contains("spawn_bot"))
            grant(["shortcuts_list", "shortcuts_run"], if: set.contains("shell"))
            grant(["plugin_call"], if: set.contains("destination_write"))
            grant(
                ["computer_screenshot", "computer_open", "computer_click", "computer_type", "computer_key", "computer_scroll"],
                if: set.contains("request_takeover")
            )
        }
        return builtinIds.filter { set.contains($0) && !enabled.contains($0) }
    }

    /// Back-compat alias.
    public static var all: [AgentToolDefinition] { builtin }

    public static var builtinIds: [String] { builtin.map(\.id) }

    /// Tools that start switched off for every bot and for new installs: the person turns them on.
    public static let optInOnlyIds: Set<String> = ["delegate_external"]

    /// The tools a new bot starts with. Opt-in tools are left out.
    public static var allIds: [String] { builtinIds.filter { !optInOnlyIds.contains($0) } }

    public static func definitions(
        custom: [CustomAgentTool] = [],
        mcpServers: [McpServer] = []
    ) -> [AgentToolDefinition] {
        builtin + mcpServers.map(\.definition) + custom.map(\.definition)
    }

    public static func allIds(
        custom: [CustomAgentTool] = [],
        mcpServers: [McpServer] = []
    ) -> [String] {
        builtinIds + mcpServers.map(\.toolId) + custom.map(\.id)
    }

    public static func label(
        for id: String,
        custom: [CustomAgentTool] = [],
        mcpServers: [McpServer] = []
    ) -> String {
        if let builtin = builtin.first(where: { $0.id == id }) { return builtin.label }
        if let mcp = mcpServers.first(where: { $0.toolId == id || $0.id == id }) { return mcp.name }
        if let custom = custom.first(where: { $0.id == id }) { return custom.name }
        return id
    }
}

extension ScriptedAction {
    /// Tool id used for enable/disable gating.
    public var toolId: String {
        switch self {
        case .writeFile: return "write_file"
        case .readFile: return "read_file"
        case .editFile: return "edit_file"
        case .moveFile: return "move_file"
        case .deleteFile: return "delete_file"
        case .listFiles: return "list_files"
        case .webSearch: return "web_search"
        case .remember: return "remember"
        case .takeover: return "request_takeover"
        case .spawnBot: return "spawn_bot"
        case .deleteBot: return "delete_bot"
        case .subagent: return "run_subagent"
        case .destinationWrite: return "destination_write"
        case .customTool(let id, _): return id
        case .mcpServer(let id, _, _): return "mcp:\(id)"
        }
    }
}

extension Bot {
    public func isToolEnabled(_ toolId: String) -> Bool {
        if enabledTools.contains(toolId) { return true }
        // Tools with a toggle of their own are on only when switched on. What is left here has no
        // toggle: the always-available basics and the two delegation read-outs.
        if CanvasBoardStore.toolIds.contains(toolId) { return true }
        if ArtifactStore.toolIds.contains(toolId) { return true }
        if toolId == "check_bot" || toolId == "list_delegations" || toolId == "stop_bot",
           enabledTools.contains("spawn_bot") || enabledTools.contains("message_bot") { return true }
        if AgentToolCatalog.alwaysOnIds.contains(toolId) { return true }
        return false
    }

    public mutating func setTool(_ toolId: String, enabled: Bool) {
        if enabled {
            if !enabledTools.contains(toolId) {
                enabledTools.append(toolId)
            }
        } else {
            enabledTools.removeAll { $0 == toolId }
        }
    }

    public mutating func setAllTools(enabled: Bool, knownIds: [String] = AgentToolCatalog.allIds) {
        enabledTools = enabled ? knownIds : []
    }

    public func allToolsEnabled(knownIds: [String] = AgentToolCatalog.allIds) -> Bool {
        Set(enabledTools) == Set(knownIds)
    }

    public var allToolsEnabled: Bool {
        allToolsEnabled(knownIds: AgentToolCatalog.allIds)
    }

    public var noToolsEnabled: Bool {
        enabledTools.isEmpty
    }

    public func isSkillEnabled(_ skillId: String) -> Bool {
        enabledSkills.contains(skillId)
    }

    public mutating func setSkill(_ skillId: String, enabled: Bool) {
        if enabled {
            if !enabledSkills.contains(skillId) {
                enabledSkills.append(skillId)
            }
        } else {
            enabledSkills.removeAll { $0 == skillId }
        }
    }
}
