import Foundation

/// When a GrizzyBot builtin is off, the next move is Toolport — not “enable it in Settings.”
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
        output.lowercased().contains("is disabled for this bot")
            || output.lowercased().contains("disabled — use toolport")
    }

    public static func promptNote(available: Set<String>) -> String? {
        let missing = routable.filter { !available.contains($0) }
        guard !missing.isEmpty else { return nil }
        if available.contains("mcp_call") {
            return "These builtins are off: \(missing.joined(separator: ", ")). Do not ask to enable them. Use mcp_call on Toolport for each job — search once (fast-filesystem for files, web search for news), then call the catalog tool with the same arguments."
        }
        return "These builtins are off: \(missing.joined(separator: ", ")). Enable one in Settings → Tools, or add Toolport under MCP and mcp_call it."
    }

    public static func loopNudge(tools: [String]) -> String {
        let names = tools.joined(separator: ", ")
        let queries = tools.map { "\($0) → \(searchQuery(for: $0))" }.joined(separator: "; ")
        return "Builtin \(names) is off. Do not ask the user to enable it and do not paste the deliverable in chat. mcp_call Toolport now: toolport_search_tools once (\(queries)), then call the matching catalog tool with the same arguments. Prefer fast-filesystem for files."
    }

    public static func toolResult(tool: String, argumentsJSON: String, hasMcp: Bool) -> String {
        if !hasMcp {
            return "Tool \(tool) is disabled for this bot. Enable it in Settings → Tools, or add Toolport under MCP."
        }
        if !isRoutable(tool) {
            return "Tool \(tool) is disabled for this bot and has no Toolport equivalent. Enable it in Settings → Tools."
        }
        let query = searchQuery(for: tool)
        var lines = [
            "Tool \(tool) is disabled for this bot. Do not ask the user to enable it.",
            "Use mcp_call on Toolport: toolport_search_tools once with query \"\(query)\", then call the matching catalog tool (prefer fast-filesystem for files) with the same arguments.",
            "Do not paste the file or brief in chat until that Toolport call succeeds. Do not call toolport_fetch_result or toolport_run_script.",
        ]
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "{}" {
            lines.append("Replay these arguments: \(trimmed)")
        }
        return lines.joined(separator: " ")
    }
}
