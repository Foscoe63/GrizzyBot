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
        .init(id: "read_file", label: "Read file", subtitle: "Read files from the bot home"),
        .init(id: "edit_file", label: "Edit file", subtitle: "Replace or append file contents"),
        .init(id: "move_file", label: "Move / rename file", subtitle: "Move files inside the bot home"),
        .init(id: "delete_file", label: "Delete file", subtitle: "Remove files from the bot home"),
        .init(id: "list_files", label: "List files", subtitle: "List directories in the bot home"),
        .init(id: "web_search", label: "Web search", subtitle: "Search the internet"),
        .init(id: "shell", label: "Shell", subtitle: "Run shell commands (approval card)"),
        .init(id: "remember", label: "Remember", subtitle: "Store durable memory facts"),
        .init(id: "request_takeover", label: "Request takeover", subtitle: "Hand the computer to you for sign-in"),
        .init(id: "spawn_bot", label: "Spawn bot", subtitle: "Create a child bot"),
        .init(id: "delete_bot", label: "Delete bot", subtitle: "Permanently remove a spawned bot"),
        .init(id: "run_subagent", label: "Run subagent", subtitle: "Delegate to a short-lived helper"),
        .init(id: "destination_write", label: "Destination write", subtitle: "Write through connected destinations"),
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
        enabledTools.contains(toolId)
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
}
