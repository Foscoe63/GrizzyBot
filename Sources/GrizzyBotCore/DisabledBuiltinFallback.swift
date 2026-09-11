import Foundation

/// When a GrizzyBot builtin is off, route to a connected MCP server — not Settings, and
/// not Toolport unless Toolport is actually enabled.
public enum DisabledBuiltinFallback: Sendable {
    public static let routable: [String] = [
        "write_file", "edit_file", "read_file", "list_files", "delete_file", "move_file",
        "web_search", "web_fetch", "shell", "destination_write",
    ]

    public static func isRoutable(_ name: String) -> Bool {
        routable.contains(name)
    }

    public static func searchQuery(for name: String) -> String {
        switch name {
        case "write_file", "edit_file": return "fast-filesystem write file"
        case "read_file": return "fast-filesystem read file"
        case "list_files": return "fast-filesystem list"
        case "delete_file": return "fast-filesystem delete"
        case "move_file": return "fast-filesystem move"
        case "web_search": return "web search"
        case "web_fetch": return "fetch url"
        case "shell": return "shell command"
        case "destination_write": return "obsidian write file"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    public static func isDisabledResult(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("is disabled for this bot")
            || lower.contains("disabled — use mcp")
            || lower.contains("disabled — use toolport")
    }

    public static func promptNote(available: Set<String>, context: McpFallbackContext = .empty) -> String? {
        let missing = routable.filter { !available.contains($0) }
        guard !missing.isEmpty else { return nil }
        if context.hasMcp || available.contains("mcp_call") {
            let names = missing.joined(separator: ", ")
            if context.hasGateway {
                return "These builtins are off: \(names). Do not ask to enable them. Use first-class MCP tools in your list, or mcp_call Toolport (search once: fast-filesystem for files, web search for news) then the catalog tool with the same arguments."
            }
            let servers = context.serverNames.isEmpty
                ? "an enabled MCP server from mcp_call's Servers list"
                : context.serverNames.joined(separator: ", ")
            return "These builtins are off: \(names). Do not ask to enable them. Use first-class MCP tools in your list (names like server__tool), or mcp_call with server=<one of: \(servers)> and the matching tool. Files → fast-filesystem. Web → ddg-search / firecrawl. Ignore standing memory that says everything goes through Toolport unless Toolport is in that server list."
        }
        return "These builtins are off: \(missing.joined(separator: ", ")). Enable one in Settings → Tools, or add an MCP server (fast-filesystem, ddg-search, …) and mcp_call it."
    }

    public static func loopNudge(tools: [String], context: McpFallbackContext = .empty) -> String {
        let names = tools.joined(separator: ", ")
        if context.hasGateway {
            let queries = tools.map { "\($0) → \(searchQuery(for: $0))" }.joined(separator: "; ")
            return "Builtin \(names) is off. Do not ask the user to enable it and do not paste the deliverable in chat. mcp_call Toolport now: toolport_search_tools once (\(queries)), then call the matching catalog tool with the same arguments. Prefer fast-filesystem for files."
        }
        let routes = tools.compactMap { McpToolRouting.preferredRoute(for: $0, context: context) }
        if let first = routes.first {
            return "Builtin \(names) is off. Do not ask the user to enable it and do not paste the deliverable in chat. \(first) Do not call Toolport unless that server is enabled."
        }
        let servers = context.serverNames.isEmpty ? "an enabled MCP server" : context.serverNames.joined(separator: ", ")
        return "Builtin \(names) is off. Do not ask the user to enable it. mcp_call server=\(servers) with the matching tool from mcp_list_tools (fast-filesystem for files, ddg-search/firecrawl for web). Do not call Toolport unless it is listed."
    }

    public static func toolResult(
        tool: String,
        argumentsJSON: String,
        hasMcp: Bool,
        context: McpFallbackContext = .empty
    ) -> String {
        if !hasMcp, !context.hasMcp {
            return "Tool \(tool) is disabled for this bot. Enable it in Settings → Tools, or add an MCP server under Tools and mcp_call it."
        }
        if !isRoutable(tool) {
            return "Tool \(tool) is disabled for this bot and has no MCP equivalent. Enable it in Settings → Tools."
        }
        var lines = [
            "Tool \(tool) is disabled for this bot. Do not ask the user to enable it.",
        ]
        if context.hasMcp, let route = McpToolRouting.preferredRoute(for: tool, context: context) {
            lines.append(route)
        } else if context.hasGateway {
            let query = searchQuery(for: tool)
            lines.append(
                "Use mcp_call on Toolport: toolport_search_tools once with query \"\(query)\", then call the matching catalog tool (prefer fast-filesystem for files) with the same arguments."
            )
        } else {
            lines.append(
                "Use mcp_call with server=<an enabled MCP from your tool list> and the matching tool. Files → fast-filesystem. Web → ddg-search / firecrawl. Do not call Toolport unless that server is listed."
            )
        }
        lines.append("Do not paste the file or brief in chat until that MCP call succeeds.")
        if context.hasGateway {
            lines.append("Do not call toolport_fetch_result or toolport_run_script.")
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "{}" {
            lines.append("Replay these arguments: \(trimmed)")
        }
        return lines.joined(separator: " ")
    }
}
