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
            || lower.contains("no route for tool")
            || lower.hasPrefix("failed to")
            || lower.contains(" 422 ")
            || lower.contains(": 422")
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
        return lines.joined(separator: "\n")
    }

    private static func isCallTool(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "toolport_call_tool" || trimmed == "conduit_call_tool"
    }

    private static func wrapCatalogCall(name: String, arguments: [String: JSONValue]) -> [String: JSONValue] {
        if let existing = arguments["arguments"] {
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
        if !inner.isEmpty {
            call["arguments"] = .object(inner)
        }
        call.removeValue(forKey: "id")
        return call
    }
}
