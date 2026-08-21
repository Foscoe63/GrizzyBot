import Foundation

/// How a first-class ChatTool should execute through `mcp_call`.
public struct McpPromotedTool: Sendable, Equatable, Hashable {
    /// Name the model sees (stable, unique).
    public var chatName: String
    /// MCP server id (e.g. Toolport's id).
    public var serverId: String
    /// Value for `mcp_call.tool` (catalog or dispatcher).
    public var executeTool: String
    /// When set, force `arguments.name` (MacUse `call_tool_by_name`, Toolport call_tool).
    public var injectName: String?
    public var description: String
    public var inputSchema: [String: AnyCodableMCP]

    public init(
        chatName: String,
        serverId: String,
        executeTool: String,
        injectName: String? = nil,
        description: String = "",
        inputSchema: [String: AnyCodableMCP] = [:]
    ) {
        self.chatName = chatName
        self.serverId = serverId
        self.executeTool = executeTool
        self.injectName = injectName
        self.description = description
        self.inputSchema = inputSchema
    }

    public var info: McpToolInfo {
        McpToolInfo(name: chatName, description: description, inputSchema: inputSchema)
    }
}

/// Promote Toolport/MacUse catalog tools to first-class LLM tools (one hop).
public enum McpCatalogPromote {
    public static let maxPromoted = 24

    public static func isDispatcher(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if McpGatewayCall.isMetaTool(t) { return true }
        if t.hasSuffix("__call_tool_by_name") || t == "call_tool_by_name" { return true }
        if t.hasSuffix("__get_tool_definitions") || t == "get_tool_definitions" { return true }
        if t.hasSuffix("__list_tools") { return true }
        return false
    }

    public static func chatTool(for promoted: McpPromotedTool) -> ChatTool {
        let schema = schemaJSONValue(promoted.inputSchema)
        let desc: String
        if promoted.injectName != nil {
            desc = "\(promoted.description.isEmpty ? promoted.chatName : promoted.description) (via MCP \(promoted.executeTool); pass this tool's args directly — do not nest call_tool_by_name)."
        } else {
            desc = promoted.description.isEmpty
                ? "MCP catalog tool \(promoted.chatName). Pass this tool's args directly."
                : promoted.description
        }
        return ChatTool(
            function: ChatToolFunction(
                name: promoted.chatName,
                description: String(desc.prefix(400)),
                parameters: schema
            )
        )
    }

    public static func chatTools(from promoted: [McpPromotedTool]) -> [ChatTool] {
        Array(promoted.prefix(maxPromoted)).map(chatTool(for:))
    }

    /// Merge newly discovered tools; prefer richer schemas; drop dispatchers.
    public static func merge(
        existing: [String: McpPromotedTool],
        adding: [McpPromotedTool]
    ) -> [String: McpPromotedTool] {
        var out = existing
        for tool in adding {
            if isDispatcher(tool.chatName) { continue }
            // Bare dispatcher without injectName is not a usable first-class tool.
            if isDispatcher(tool.executeTool), tool.injectName == nil { continue }
            if let prev = out[tool.chatName] {
                let prevProps = propertyCount(prev.inputSchema)
                let nextProps = propertyCount(tool.inputSchema)
                if nextProps >= prevProps {
                    out[tool.chatName] = tool
                }
            } else {
                out[tool.chatName] = tool
            }
        }
        if out.count > maxPromoted * 2 {
            let trimmed = out.values.sorted { $0.chatName < $1.chatName }.suffix(maxPromoted)
            out = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.chatName, $0) })
        }
        return out
    }

    // MARK: - Harvest from tool results

    public static func harvest(
        serverId: String,
        catalogTool: String,
        text: String
    ) -> [McpPromotedTool] {
        let lower = catalogTool.lowercased()
        if lower.contains("search_tools") || lower.contains("toolport_search") {
            return harvestSearch(serverId: serverId, text: text)
        }
        if lower.contains("get_tool_definitions") {
            return harvestDefinitions(serverId: serverId, catalogTool: catalogTool, text: text)
        }
        return harvestBacktickNames(serverId: serverId, text: text)
    }

    public static func harvestSearch(serverId: String, text: String) -> [McpPromotedTool] {
        var names = extractBacktickNames(text)
        names.append(contentsOf: extractPrefixedCatalogNames(text))
        var seen = Set<String>()
        var out: [McpPromotedTool] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isDispatcher(trimmed), seen.insert(trimmed).inserted else { continue }
            out.append(
                McpPromotedTool(
                    chatName: trimmed,
                    serverId: serverId,
                    executeTool: trimmed,
                    description: "Toolport catalog tool. Call with this tool's arguments."
                )
            )
        }
        return out
    }

    /// MacUse (and similar): definitions for concrete tools behind `call_tool_by_name`.
    public static func harvestDefinitions(
        serverId: String,
        catalogTool: String,
        text: String
    ) -> [McpPromotedTool] {
        let dispatcher = callByNameDispatcher(from: catalogTool) ?? "macuse__call_tool_by_name"
        let prefix = serverPrefix(from: catalogTool) ?? serverPrefix(from: dispatcher) ?? "macuse"
        var out: [McpPromotedTool] = []

        if let tools = parseToolsJSONArray(text) {
            for item in tools {
                guard let rawName = item["name"] as? String else { continue }
                let inner = stripPrefix(rawName, prefix: prefix)
                guard !inner.isEmpty, !isDispatcher(inner) else { continue }
                let chatName = "\(prefix)__\(inner)"
                let description = item["description"] as? String ?? ""
                let schema = (item["inputSchema"] as? [String: Any])
                    ?? (item["input_schema"] as? [String: Any])
                    ?? [:]
                out.append(
                    McpPromotedTool(
                        chatName: chatName,
                        serverId: serverId,
                        executeTool: dispatcher,
                        injectName: inner,
                        description: description,
                        inputSchema: schema.mapValues(AnyCodableMCP.init)
                    )
                )
            }
        }

        // Fallback: bare tool names mentioned in prose / error hints.
        for name in extractBareToolHints(text) {
            let inner = stripPrefix(name, prefix: prefix)
            guard !inner.isEmpty, !isDispatcher(inner) else { continue }
            let chatName = "\(prefix)__\(inner)"
            if out.contains(where: { $0.chatName == chatName }) { continue }
            out.append(
                McpPromotedTool(
                    chatName: chatName,
                    serverId: serverId,
                    executeTool: dispatcher,
                    injectName: inner,
                    description: "MacUse tool \(inner). Pass args directly."
                )
            )
        }
        return out
    }

    public static func harvestBacktickNames(serverId: String, text: String) -> [McpPromotedTool] {
        harvestSearch(serverId: serverId, text: text)
    }

    // MARK: - Warm queries from user prompt

    public static func warmQueries(from prompt: String) -> [(server: String?, query: String)] {
        let lower = prompt.lowercased()
        var out: [(String?, String)] = []
        func add(server: String?, query: String) {
            if out.contains(where: { $0.1 == query && $0.0 == server }) { return }
            out.append((server, query))
        }
        if lower.contains("gmail") || lower.contains("email") || lower.contains("inbox") {
            add(server: "gmail", query: "gmail")
        }
        if lower.contains("macuse") || lower.contains("mac use") {
            add(server: "macuse", query: "macuse")
        }
        if lower.contains("obsidian") || lower.contains("vault") {
            add(server: "obsidian", query: "obsidian")
        }
        if lower.contains("github") {
            add(server: "github", query: "github")
        }
        if lower.contains("calendar") {
            add(server: "macuse", query: "calendar")
        }
        return Array(out.prefix(2))
    }

    // MARK: - Execute rewrite

    /// Build `mcp_call` arguments for a promoted tool.
    public static func mcpCallArguments(
        promoted: McpPromotedTool,
        raw: [String: JSONValue]
    ) -> [String: JSONValue] {
        var args = McpCallArguments.resolve(raw)
        args.removeValue(forKey: "server")
        args.removeValue(forKey: "tool")
        if let inject = promoted.injectName {
            args["name"] = .string(inject)
        }
        var out: [String: JSONValue] = [
            "server": .string(promoted.serverId),
            "tool": .string(promoted.executeTool),
            "arguments": .object(args),
        ]
        // Also flatten for gateways that read top-level.
        if let inject = promoted.injectName {
            out["name"] = .string(inject)
        }
        for (key, value) in args where key != "name" {
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    // MARK: - Parsing helpers

    private static func schemaJSONValue(_ schema: [String: AnyCodableMCP]) -> JSONValue {
        if schema.isEmpty {
            return .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(true),
            ])
        }
        let anySchema = schema.mapValues(\.value) as [String: Any]
        var converted = JSONValue.from(anySchema)
        if case .object(var obj) = converted {
            if obj["type"] == nil { obj["type"] = .string("object") }
            if obj["properties"] == nil { obj["properties"] = .object([:]) }
            converted = .object(obj)
        } else {
            converted = .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(true),
            ])
        }
        return converted
    }

    private static func propertyCount(_ schema: [String: AnyCodableMCP]) -> Int {
        ((schema["properties"]?.value as? [String: Any]) ?? [:]).count
    }

    private static func extractBacktickNames(_ text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let start = rest.firstIndex(of: "`") {
            let after = rest.index(after: start)
            guard let end = rest[after...].firstIndex(of: "`") else { break }
            let name = String(rest[after..<end])
            if name.contains("__") || name.contains("_"), name.count < 120, !name.contains(" ") {
                names.append(name)
            }
            rest = rest[rest.index(after: end)...]
        }
        return names
    }

    private static func extractPrefixedCatalogNames(_ text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_])([a-z][a-z0-9_-]*__[a-zA-Z0-9_.-]{2,80})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func extractBareToolHints(_ text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_])((?:mail|calendar|notes|reminders|contacts|messages)_[a-z0-9_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func parseToolsJSONArray(_ text: String) -> [[String: Any]]? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data)
        {
            if let dict = obj as? [String: Any] {
                if let tools = dict["tools"] as? [[String: Any]] { return tools }
                if let tools = dict["definitions"] as? [[String: Any]] { return tools }
                if let tools = dict["result"] as? [[String: Any]] { return tools }
                if dict["name"] != nil { return [dict] }
            }
            if let arr = obj as? [[String: Any]] { return arr }
        }
        if let start = text.firstIndex(of: "{") ?? text.firstIndex(of: "["),
           let data = String(text[start...]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data)
        {
            if let dict = obj as? [String: Any] {
                if let tools = dict["tools"] as? [[String: Any]] { return tools }
                if let tools = dict["definitions"] as? [[String: Any]] { return tools }
            }
            if let arr = obj as? [[String: Any]] { return arr }
        }
        return nil
    }

    private static func callByNameDispatcher(from catalogTool: String) -> String? {
        let t = catalogTool.lowercased()
        if t.contains("get_tool_definitions") {
            if let range = catalogTool.range(of: "get_tool_definitions", options: .caseInsensitive) {
                var out = catalogTool
                out.replaceSubrange(range, with: "call_tool_by_name")
                return out
            }
        }
        if t.contains("call_tool_by_name") { return catalogTool }
        if t.hasPrefix("macuse") { return "macuse__call_tool_by_name" }
        return nil
    }

    private static func serverPrefix(from name: String) -> String? {
        if let range = name.range(of: "__") {
            return String(name[..<range.lowerBound])
        }
        return nil
    }

    private static func stripPrefix(_ name: String, prefix: String) -> String {
        let p = prefix + "__"
        if name.hasPrefix(p) { return String(name.dropFirst(p.count)) }
        if name.hasPrefix(prefix + "_") { return String(name.dropFirst(prefix.count + 1)) }
        return name
    }
}
