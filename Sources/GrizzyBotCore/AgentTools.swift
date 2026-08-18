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

    public static func parseArgs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    public static func argsLine(_ args: [String]) -> String {
        args.joined(separator: " ")
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
        .init(id: "write_file", label: "Write file", subtitle: "Create or overwrite files in the bot home"),
        .init(id: "read_file", label: "Read file", subtitle: "Read bot-home or absolute paths on this Mac"),
        .init(id: "edit_file", label: "Edit file", subtitle: "Replace or append file contents"),
        .init(id: "move_file", label: "Move / rename file", subtitle: "Move files inside the bot home"),
        .init(id: "delete_file", label: "Delete file", subtitle: "Remove files from the bot home"),
        .init(id: "list_files", label: "List files", subtitle: "List bot-home or absolute folders on this Mac"),
        .init(id: "web_search", label: "Web search", subtitle: "Search the internet and fetch pages"),
        .init(id: "shell", label: "Shell", subtitle: "Run shell commands in the bot home"),
        .init(id: "remember", label: "Remember", subtitle: "Store durable memory facts"),
        .init(id: "search_memory", label: "Search memory", subtitle: "Retrieve facts from bot and shared memory"),
        .init(id: "request_takeover", label: "Request takeover", subtitle: "Hand the computer to you for sign-in"),
        .init(id: "spawn_bot", label: "Spawn bot", subtitle: "Create a child bot"),
        .init(id: "delete_bot", label: "Delete bot", subtitle: "Permanently remove a spawned bot"),
        .init(id: "run_subagent", label: "Run subagent", subtitle: "Delegate to a short-lived helper"),
        .init(id: "destination_write", label: "Destination write", subtitle: "Write through connected destinations"),
        .init(id: "computer_screenshot", label: "Screenshot", subtitle: "Capture the live computer screen"),
        .init(id: "computer_open", label: "Open URL", subtitle: "Open a URL on the computer"),
        .init(id: "computer_click", label: "Click", subtitle: "Click on the computer screen"),
        .init(id: "computer_type", label: "Type", subtitle: "Type into the computer"),
        .init(id: "computer_key", label: "Key", subtitle: "Press a key on the computer"),
        .init(id: "plugin_call", label: "Plugin call", subtitle: "Search or write through a connected plugin"),
        .init(id: "read_skill", label: "Read skill", subtitle: "Load a skill's full instructions"),
        .init(id: "import_skills", label: "Import skills", subtitle: "Copy SKILL.md folders into GrizzyBot"),
    ]

    /// Back-compat alias.
    public static var all: [AgentToolDefinition] { builtin }

    public static var builtinIds: [String] { builtin.map(\.id) }

    /// Back-compat alias for defaults.
    public static var allIds: [String] { builtinIds }

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
        if toolId.hasPrefix("computer_"), enabledTools.contains("request_takeover") { return true }
        if toolId == "plugin_call", enabledTools.contains("destination_write") { return true }
        if toolId == "search_memory", enabledTools.contains("remember") { return true }
        if toolId == "import_skills", enabledTools.contains("read_file") { return true }
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

extension AgentToolCatalog {
    private static func objectSchema(
        _ properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    /// OpenAI/Anthropic function tools for a bot's enabled set.
    public static func chatTools(
        enabledIds: [String],
        mcpServers: [McpServer] = [],
        includeDelegation: Bool = true,
        skills: [AgentSkill] = []
    ) -> [ChatTool] {
        let enabled = Set(enabledIds)
            .union(enabledIds.contains("read_file") ? ["import_skills"] : [])
        var tools: [ChatTool] = []

        func add(_ id: String, name: String? = nil, description: String, properties: [String: JSONValue], required: [String]) {
            guard enabled.contains(id) else { return }
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: name ?? id,
                        description: description,
                        parameters: objectSchema(properties, required: required)
                    )
                )
            )
        }

        add(
            "write_file",
            description: "Write a UTF-8 file into this bot's private home. It shows up in Files.",
            properties: [
                "path": stringProp("Relative path inside the bot home, e.g. notes/result.txt"),
                "content": stringProp("Full file contents"),
            ],
            required: ["path", "content"]
        )
        add(
            "read_file",
            description: "Read a UTF-8 file from this bot's home, or an absolute/~ path on this Mac (for example /Users/me/.agents/skills/orchestration/SKILL.md).",
            properties: ["path": stringProp("Relative bot-home path or absolute/~ path")],
            required: ["path"]
        )
        add(
            "edit_file",
            description: "Replace or append a file in this bot's home.",
            properties: [
                "path": stringProp("Relative path"),
                "content": stringProp("New contents, or text to append"),
                "mode": .object([
                    "type": .string("string"),
                    "description": .string("replace (default) or append"),
                ]),
            ],
            required: ["path", "content"]
        )
        add(
            "move_file",
            description: "Move or rename a file inside this bot's home.",
            properties: [
                "from": stringProp("Source relative path"),
                "to": stringProp("Destination relative path"),
            ],
            required: ["from", "to"]
        )
        add(
            "delete_file",
            description: "Delete a file or directory inside this bot's home.",
            properties: ["path": stringProp("Relative path")],
            required: ["path"]
        )
        add(
            "list_files",
            description: "List a directory in this bot's home, or an absolute/~ folder on this Mac.",
            properties: ["directory": stringProp("Relative directory, empty for home root, or an absolute/~ path")],
            required: []
        )
        add(
            "web_search",
            description: "Search the public web. Use this for current facts, docs, and links.",
            properties: ["query": stringProp("Search query")],
            required: ["query"]
        )
        if enabled.contains("web_search") {
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "web_fetch",
                        description: "Fetch a public http(s) URL and return text (HTML stripped when possible).",
                        parameters: objectSchema(
                            ["url": stringProp("Absolute http or https URL")],
                            required: ["url"]
                        )
                    )
                )
            )
        }
        add(
            "shell",
            description: "Run a shell command with cwd in this bot's home. stdout/stderr are returned.",
            properties: [
                "command": stringProp("Command passed to zsh -lc"),
                "cwd": stringProp("Optional subdirectory of the bot home"),
            ],
            required: ["command"]
        )
        add(
            "remember",
            description: "Store a durable fact. scope=bot (default) writes MEMORY.md for this bot; scope=shared writes workspace memory every bot can read.",
            properties: [
                "content": stringProp("Fact to remember"),
                "scope": stringProp("bot or shared"),
            ],
            required: ["content"]
        )
        if enabled.contains("remember") || enabled.contains("search_memory") {
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "search_memory",
                        description: "Search bot-local and shared workspace memory. Use this instead of guessing past facts.",
                        parameters: objectSchema(
                            ["query": stringProp("Keywords to find")],
                            required: ["query"]
                        )
                    )
                )
            )
        }
        add(
            "request_takeover",
            description: "Ask the user to take over the computer for login or human judgment.",
            properties: ["reason": stringProp("Why you need the user")],
            required: ["reason"]
        )
        add(
            "destination_write",
            description: "Write a record to a connected plugin (GitHub gist, Slack, Linear, …) and the local destination log.",
            properties: [
                "title": stringProp("Short title"),
                "body": stringProp("Body to write"),
                "slug": stringProp("Optional plugin slug, e.g. github"),
            ],
            required: ["title", "body"]
        )
        add(
            "computer_screenshot",
            description: "Capture a JPEG of this bot's live computer screen. The image is attached for you to see.",
            properties: [:],
            required: []
        )
        add(
            "computer_open",
            description: "Open a file:// or http(s) URL on the bot computer.",
            properties: ["url": stringProp("Absolute URL")],
            required: ["url"]
        )
        add(
            "computer_click",
            description: "Click on the computer screen at pixel coordinates.",
            properties: [
                "x": stringProp("X pixel"),
                "y": stringProp("Y pixel"),
            ],
            required: ["x", "y"]
        )
        add(
            "computer_type",
            description: "Type text into the computer (focused field or page).",
            properties: ["text": stringProp("Text to type")],
            required: ["text"]
        )
        add(
            "computer_key",
            description: "Press a keyboard key on the computer (Enter, Escape, Tab, Backspace, or a character).",
            properties: ["key": stringProp("Key name, e.g. Enter")],
            required: ["key"]
        )
        add(
            "plugin_call",
            description: "Call a connected plugin. action=search|list|get reads; action=write (default) sends a title/body.",
            properties: [
                "slug": stringProp("Plugin slug, e.g. gmail or github"),
                "action": stringProp("search, list, get, or write"),
                "query": stringProp("Search/list query for reads"),
                "title": stringProp("Title for writes"),
                "body": stringProp("Body for writes"),
            ],
            required: ["slug"]
        )
        add(
            "import_skills",
            description: "Import every SKILL.md under a folder into GrizzyBot’s skill library so bots can use them. Path may be absolute (e.g. ~/.agents/skills) or inside the bot home.",
            properties: ["path": stringProp("Folder that contains SKILL.md files")],
            required: ["path"]
        )
        if !skills.isEmpty {
            let ids = skills.map(\.id).joined(separator: ", ")
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "read_skill",
                        description: "Load the full instructions for a skill before you follow it. Skills: \(ids).",
                        parameters: objectSchema(
                            ["id": stringProp("Skill id from the catalog, e.g. research")],
                            required: ["id"]
                        )
                    )
                )
            )
        }
        if includeDelegation {
            add(
                "run_subagent",
                description: "Run a short-lived helper for this turn only. It is not a listed bot. Use spawn_bot to create a real bot.",
                properties: [
                    "name": stringProp("Short label, e.g. scout"),
                    "task": stringProp("Work the helper should complete"),
                    "instructions": stringProp("Optional extra instructions"),
                ],
                required: ["name", "task"]
            )
            add(
                "spawn_bot",
                description: "Create a full peer bot with its own thread, home, and memory. Appears in the bot list.",
                properties: [
                    "name": stringProp("Bot name"),
                    "title": stringProp("Short role title"),
                    "instructions": stringProp("Standing instructions for the new bot"),
                    "prompt": stringProp("Optional first task to run in the new bot's thread"),
                ],
                required: ["name"]
            )
            add(
                "delete_bot",
                description: "Permanently delete a bot this bot created. confirm_name must match exactly.",
                properties: [
                    "confirm_name": stringProp("Exact name of the bot to delete"),
                    "bot_id": stringProp("Optional bot id"),
                ],
                required: ["confirm_name"]
            )
        }

        let mcpEnabled = mcpServers.filter { enabled.contains($0.toolId) }
        if !mcpEnabled.isEmpty {
            let names = mcpEnabled.map(\.name).joined(separator: ", ")
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "mcp_list_tools",
                        description: "List tools exposed by a configured MCP server. Servers: \(names).",
                        parameters: objectSchema(
                            ["server": stringProp("MCP server name or id")],
                            required: ["server"]
                        )
                    )
                )
            )
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "mcp_call",
                        description: "Call a tool on a configured MCP server. Servers: \(names). Pass the MCP tool's own fields (filepath, content, …) either nested in arguments or as top-level parameters. write_file cannot write an Obsidian vault.",
                        parameters: objectSchema(
                            [
                                "server": stringProp("MCP server name or id"),
                                "tool": stringProp("Tool name from mcp_list_tools"),
                                "arguments": .object([
                                    "type": .string("object"),
                                    "description": .string("Arguments object for the MCP tool"),
                                ]),
                                "prompt": stringProp("Fallback text if the server expects a single prompt"),
                            ],
                            required: ["server"]
                        )
                    )
                )
            )
        }

        return tools
    }
}
