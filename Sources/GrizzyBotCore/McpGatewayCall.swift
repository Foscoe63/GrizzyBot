import Foundation

/// Result of shaping an `mcp_call` so lazy MCP gateways (Toolport) accept catalog names.
public struct McpPreparedCall: Sendable, Equatable {
    public var toolName: String
    public var arguments: [String: JSONValue]
    public var note: String?

    public init(toolName: String, arguments: [String: JSONValue], note: String? = nil) {
        self.toolName = toolName
        self.arguments = arguments
        self.note = note
    }
}

/// Toolport advertises meta-tools, not GitHub/Obsidian. Unwrap catalog names and `id` → `name`.
public enum McpGatewayCall {
    public static func isGateway(_ server: McpServer) -> Bool {
        let blob = ([
            server.name, server.id, server.command, server.url,
        ] + server.args).joined(separator: " ").lowercased()
        return blob.contains("toolport") || blob.contains("toolport-gateway") || blob.contains("conduit-gateway")
    }

    public static func isMetaTool(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("toolport_") || trimmed.hasPrefix("conduit_")
    }

    public static func isCallTool(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "toolport_call_tool" || trimmed == "conduit_call_tool"
    }

    public static func prepare(
        server: McpServer,
        toolName: String,
        raw: [String: JSONValue]
    ) -> McpPreparedCall {
        let resolved = McpCallArguments.resolve(raw)
        guard isGateway(server) else {
            return McpPreparedCall(toolName: toolName, arguments: resolved)
        }
        if isMetaTool(toolName) {
            if isCallTool(toolName) {
                return McpPreparedCall(toolName: toolName, arguments: normalizeCallToolArguments(resolved))
            }
            return McpPreparedCall(toolName: toolName, arguments: resolved)
        }
        let wrapped = wrapCatalogCall(name: toolName, arguments: resolved)
        return McpPreparedCall(
            toolName: "toolport_call_tool",
            arguments: wrapped,
            note: "Wrapped \(toolName) as toolport_call_tool with arguments.name. Do not search Toolport again this turn."
        )
    }

    /// `toolport_call_tool` with a blank catalog name — refuse before the gateway returns `no route for tool ''`.
    public static func missingCatalogName(_ prepared: McpPreparedCall) -> Bool {
        guard isCallTool(prepared.toolName) else { return false }
        if case .string(let name) = prepared.arguments["name"] {
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    public static func missingCatalogNameMessage() -> String {
        """
        mcp_call toolport_call_tool requires arguments.name = the exact catalog tool \
        (example: mcp_obsidian_advanced__obsidian_put_file). Call toolport_search_tools once, \
        copy that name, then retry. Do not call toolport_call_tool with an empty name.
        """
    }

    public static func catalogToolName(_ prepared: McpPreparedCall) -> String {
        if isCallTool(prepared.toolName), case .string(let name) = prepared.arguments["name"] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return prepared.toolName
    }

    public static func failed(isError: Bool, text: String) -> Bool {
        if isError { return true }
        let lower = text.lowercased()
        return lower.contains("validation failed")
            || lower.contains("input validation error")
            || lower.contains("is a required property")
            || lower.contains("no route for tool")
            || lower.hasPrefix("failed to")
            || lower.contains(" 422 ")
            || lower.contains(": 422")
            || lower.contains("unknown or expired")
            || lower.contains("unexpected argument")
            || lower.contains("fetch is not defined")
            || lower.contains("process is not defined")
            || lower.contains("max retries exceeded")
            || lower.contains("connection refused")
            || lower.contains("newconnectionerror")
            || lower.contains("could not connect")
            || lower.contains("wrong_version_number")
            || lower.contains("sslerror")
    }

    /// Transient transport failures worth one automatic retry.
    public static func isTransientFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Protocol mismatch (HTTPS→HTTP port) will not recover on retry.
        if lower.contains("wrong_version_number") { return false }
        return lower.contains("max retries exceeded")
            || lower.contains("connection refused")
            || lower.contains("newconnectionerror")
            || lower.contains("temporarily unavailable")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("econnreset")
            || lower.contains("socket hang up")
            || lower.contains("503")
            || lower.contains("502")
    }

    /// Gateway loops that will not finish the user's job: expired cursors, missing routes, code-mode debugging.
    public static func isDeadEnd(_ text: String) -> Bool {
        if failed(isError: false, text: text) { return true }
        let lower = text.lowercased()
        return (lower.contains("cursor") && lower.contains("expired"))
            || lower.contains("run_script unexpected")
            || lower.contains("inputschema")
            || lower.contains("parseerror")
            || lower.contains("[object object]")
    }

    public static func recoveryHint(for text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("wrong_version_number") || (lower.contains("sslerror") && (lower.contains("27123") || lower.contains("27124"))) {
            return """
            Obsidian Local REST API protocol mismatch. Port 27123 is HTTP only; 27124 is HTTPS (self-signed). \
            In Toolport / the Obsidian MCP server config use either http://127.0.0.1:27123 (with insecure HTTP enabled in the plugin) \
            or https://127.0.0.1:27124 with TLS verify disabled / the plugin certificate trusted — do not use https:// on :27123. \
            Firefox showing status OK on http://127.0.0.1:27123 means the HTTP server is fine; fix the MCP base URL scheme.
            """
        }
        if lower.contains("27124") || lower.contains("27123") || (lower.contains("obsidian") && isTransientFailure(text)) {
            return "Obsidian Local REST API is not reachable. Prefer https://127.0.0.1:27124 (HTTPS) or http://127.0.0.1:27123 (HTTP). Start Obsidian with Local REST API enabled, or write the note with write_file under notes/ and tell the user to move it into the vault."
        }
        if lower.contains("is a required property") || lower.contains("input validation error") {
            return "Required arguments were missing. Use the exact arg names from toolport_search_tools / mcp_list_tools (filepath+content for put_file, dirpath for list). Prefer path→filepath aliases already applied — pass the missing field explicitly and retry once."
        }
        if lower.contains("no route for tool") {
            return "That catalog tool name is not routed. Call toolport_search_tools once for the app (e.g. query \"obsidian put file\"), then mcp_call with the exact returned name. Do not invent tool names."
        }
        if isTransientFailure(text) {
            return "Transient connection failure. Retry the same mcp_call once; if it fails again, fall back to write_file or web tools and report the outage."
        }
        return nil
    }

    public static func snippet(_ text: String, limit: Int = 220) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "" }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    public static func cardLines(
        serverName: String,
        prepared: McpPreparedCall,
        isError: Bool,
        text: String
    ) -> [CardLine] {
        cardLines(
            serverName: serverName,
            catalogTool: catalogToolName(prepared),
            gatewayTool: prepared.toolName,
            isError: isError,
            text: text
        )
    }

    public static func cardLines(
        serverName: String,
        catalogTool: String,
        gatewayTool: String,
        isError: Bool,
        text: String
    ) -> [CardLine] {
        let failed = failed(isError: isError, text: text)
        var lines = [
            CardLine(k: "mcp", v: serverName),
            CardLine(k: "tool", v: catalogTool.isEmpty ? gatewayTool : catalogTool),
            CardLine(k: "status", v: failed ? "tool error" : "ok"),
        ]
        if isCallTool(gatewayTool), catalogTool != gatewayTool, !catalogTool.isEmpty {
            lines.insert(CardLine(k: "via", v: gatewayTool), at: 2)
        }
        let out = snippet(text)
        if !out.isEmpty {
            lines.append(CardLine(k: "out", v: out))
        }
        return lines
    }

    public static func modelOutput(prepared: McpPreparedCall, isError: Bool, text: String) -> String {
        let catalog = catalogToolName(prepared)
        let failed = failed(isError: isError, text: text)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = failed ? "tool error" : "ok"
        let core = body.isEmpty ? status : body
        var lines: [String] = []
        if let note = prepared.note, !note.isEmpty {
            lines.append(note)
        }
        lines.append("[\(catalog)] \(status)")
        if !body.isEmpty {
            lines.append(core)
        }
        if failed, let hint = recoveryHint(for: text) {
            lines.append(hint)
        }
        return lines.joined(separator: "\n")
    }

    private static func wrapCatalogCall(name: String, arguments: [String: JSONValue]) -> [String: JSONValue] {
        if let existing = arguments["arguments"] {
            if case .object(let obj) = existing {
                return ["name": .string(name), "arguments": .object(McpCallArguments.applyAliases(obj))]
            }
            return ["name": .string(name), "arguments": existing]
        }
        return ["name": .string(name), "arguments": .object(arguments)]
    }

    private static func normalizeCallToolArguments(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var call = args
        if call["name"] == nil {
            if case .string(let id) = call["id"] {
                call["name"] = .string(id)
                call.removeValue(forKey: "id")
            } else if case .string(let id) = call["arguments"]?.objectValue()["id"] {
                call["name"] = .string(id)
            } else if case .string(let tool) = call["tool"] {
                let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !isCallTool(trimmed), !isMetaTool(trimmed) {
                    call["name"] = .string(trimmed)
                }
            }
        }
        var inner = call["arguments"]?.objectValue() ?? [:]
        inner.removeValue(forKey: "id")
        let skip: Set<String> = ["name", "arguments", "id"]
        for (key, value) in call where !skip.contains(key) {
            if inner[key] == nil {
                inner[key] = value
            }
            call.removeValue(forKey: key)
        }
        inner = McpCallArguments.applyAliases(inner)
        if !inner.isEmpty {
            call["arguments"] = .object(inner)
        }
        call.removeValue(forKey: "id")
        return call
    }
}
