import Foundation

/// First-class MCP names follow GrizzyClaw: `server-slug__tool` unless the catalog
/// name is already namespaced (`gmail__messages_list`).
public enum McpNativeNaming: Sendable {
    public static let separator = "__"

    public static func slug(_ server: McpServer) -> String {
        let raw = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? server.id : slug
    }

    public static func composite(serverSlug: String, tool: String) -> String {
        let toolName = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if toolName.contains(separator) { return toolName }
        return "\(serverSlug)\(separator)\(toolName)"
    }

    public static func chatName(server: McpServer, tool: String) -> String {
        composite(serverSlug: slug(server), tool: tool)
    }

    public static func split(_ name: String) -> (server: String, tool: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: separator) else { return nil }
        let server = String(trimmed[..<range.lowerBound])
        let tool = String(trimmed[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }
}

/// Lightweight MCP server facts for prompts and disabled-builtin recovery.
public struct McpServerRef: Sendable, Equatable {
    public var id: String
    public var name: String
    public var isGateway: Bool

    public init(id: String, name: String, isGateway: Bool) {
        self.id = id
        self.name = name
        self.isGateway = isGateway
    }

    public init(_ server: McpServer) {
        self.init(id: server.id, name: server.name, isGateway: McpGatewayCall.isGateway(server))
    }
}

public struct McpFallbackContext: Sendable, Equatable {
    public var servers: [McpServerRef]
    public var advertised: [String: [String]]
    public var firstClassNames: [String]

    public static let empty = McpFallbackContext(servers: [], advertised: [:], firstClassNames: [])

    public init(
        servers: [McpServerRef],
        advertised: [String: [String]] = [:],
        firstClassNames: [String] = []
    ) {
        self.servers = servers
        self.advertised = advertised
        self.firstClassNames = firstClassNames
    }

    public var hasMcp: Bool { !servers.isEmpty }
    public var hasGateway: Bool { servers.contains(where: \.isGateway) }
    public var serverNames: [String] { servers.map(\.name) }

    public static func from(tools: [ChatTool]) -> McpFallbackContext {
        let names = tools.map(\.function.name)
        let call = tools.first { $0.function.name == "mcp_call" }
        let desc = call?.function.description ?? ""
        let listed = McpToolRouting.parseServerList(from: desc)
        let gateway = desc.lowercased().contains("toolport")
            || desc.lowercased().contains("conduit-gateway")
        let refs = listed.map { name in
            McpServerRef(
                id: name,
                name: name,
                isGateway: gateway && name.lowercased().contains("toolport")
            )
        }
        return McpFallbackContext(
            servers: refs,
            firstClassNames: names.filter { $0.contains(McpNativeNaming.separator) }
        )
    }

    public static func from(servers: [McpServer], advertised: [String: [String]] = [:], firstClassNames: [String] = []) -> McpFallbackContext {
        McpFallbackContext(
            servers: servers.map(McpServerRef.init),
            advertised: advertised,
            firstClassNames: firstClassNames
        )
    }
}

public enum McpDirectHit: Equatable, Sendable {
    case promoted(McpPromotedTool)
    case advertised(serverId: String, toolName: String)
    case missingGateway(tool: String)
}

public enum McpServerResolution: Equatable, Sendable {
    case resolved(McpServer)
    case failed(String)
}

/// Server/tool identity + omit-`server` resolution (GrizzyClaw-style; no default-to-first-MCP).
public enum McpToolRouting: Sendable {
    public static func parseServerList(from description: String) -> [String] {
        let marker = "Servers: "
        guard let start = description.range(of: marker) else { return [] }
        let rest = description[start.upperBound...]
        let end = rest.firstIndex(of: ".") ?? rest.endIndex
        return String(rest[..<end])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func canonicalServer(_ raw: String, in servers: [McpServer]) -> McpServer? {
        let needle = stripDecor(raw).lowercased()
        guard !needle.isEmpty else { return nil }
        var cur = needle
        for _ in 0..<6 {
            if let hit = uniqueMatch(cur, in: servers) { return hit }
            if cur.hasPrefix("user-") {
                cur = String(cur.dropFirst(5))
                continue
            }
            if cur.hasPrefix("mcp:") {
                cur = String(cur.dropFirst(4))
                continue
            }
            let hyphen = cur.replacingOccurrences(of: "_", with: "-")
            if hyphen != cur {
                cur = hyphen
                continue
            }
            break
        }
        return uniqueMatch(needle, in: servers)
    }

    public static func canonicalTool(_ raw: String, known: [String], allowSingleFallback: Bool = false) -> String? {
        let trimmed = stripDecor(raw)
        guard !trimmed.isEmpty else { return nil }
        if known.contains(trimmed) { return trimmed }
        let ci = known.filter { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        if ci.count == 1 { return ci[0] }
        let hyphen = trimmed.replacingOccurrences(of: "_", with: "-")
        let under = trimmed.replacingOccurrences(of: "-", with: "_")
        let swapped = known.filter { $0 == hyphen || $0 == under }
        if swapped.count == 1 { return swapped[0] }
        if allowSingleFallback, known.count == 1 { return known[0] }
        return nil
    }

    /// Which enabled server owns this tool name. Unique advertised match wins.
    public static func serverOwning(
        tool raw: String,
        servers: [McpServer],
        advertised: [String: [String]]
    ) -> (server: McpServer, tool: String)? {
        let trimmed = stripDecor(raw)
        guard !trimmed.isEmpty else { return nil }

        if let split = McpNativeNaming.split(trimmed),
           let server = canonicalServer(split.server, in: servers) {
            let known = advertised[server.id] ?? []
            if let tool = canonicalTool(split.tool, known: known, allowSingleFallback: true)
                ?? (known.isEmpty ? split.tool : nil) {
                return (server, tool)
            }
        }

        var exact: [(McpServer, String)] = []
        for server in servers {
            let known = advertised[server.id] ?? []
            if let tool = canonicalTool(trimmed, known: known) {
                exact.append((server, tool))
            }
        }
        if exact.count == 1 { return exact[0] }

        var prefixed: [(McpServer, String)] = []
        for server in servers {
            let slug = McpNativeNaming.slug(server)
            let under = slug.replacingOccurrences(of: "-", with: "_")
            let known = advertised[server.id] ?? []
            for prefix in [slug + McpNativeNaming.separator, under + "_", slug + "_"] where trimmed.lowercased().hasPrefix(prefix) {
                let rest = String(trimmed.dropFirst(prefix.count))
                if rest.isEmpty { continue }
                if let tool = canonicalTool(rest, known: known) ?? (known.isEmpty ? rest : nil) {
                    prefixed.append((server, tool))
                }
            }
            if let tokenHit = firstTokenMatch(trimmed, server: server, known: known) {
                prefixed.append(tokenHit)
            }
        }
        let uniquePrefixed = uniqued(prefixed)
        if uniquePrefixed.count == 1 { return uniquePrefixed[0] }
        return nil
    }

    public static func resolveServer(
        requested: String,
        toolName: String = "",
        enabled: [McpServer],
        advertised: [String: [String]] = [:]
    ) -> McpServerResolution {
        if enabled.isEmpty {
            return .failed("No MCP servers are enabled for this bot. Add a server under Settings → Tools and enable it.")
        }
        let needle = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            if let match = canonicalServer(needle, in: enabled) {
                return .resolved(match)
            }
            return .failed(unknownServerMessage(requested: needle, enabled: enabled))
        }
        if let owned = serverOwning(tool: toolName, servers: enabled, advertised: advertised) {
            return .resolved(owned.server)
        }
        if McpGatewayCall.isMetaTool(toolName),
           let gateway = enabled.first(where: { McpGatewayCall.isGateway($0) }) {
            return .resolved(gateway)
        }
        if toolName.contains(McpNativeNaming.separator),
           let gateway = enabled.first(where: { McpGatewayCall.isGateway($0) }) {
            return .resolved(gateway)
        }
        if enabled.count == 1 {
            return .resolved(enabled[0])
        }
        return .failed(needServerMessage(enabled: enabled))
    }

    public static func resolveDirectTool(
        name: String,
        promoted: [String: McpPromotedTool],
        servers: [McpServer],
        advertised: [String: [String]]
    ) -> McpDirectHit? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hit = promoted[trimmed] { return .promoted(hit) }
        if let ci = promoted.first(where: { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .promoted(ci.value)
        }
        let executeHits = promoted.values.filter {
            $0.executeTool.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.chatName.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if executeHits.count == 1 { return .promoted(executeHits[0]) }
        if McpGatewayCall.isMetaTool(trimmed), !servers.contains(where: { McpGatewayCall.isGateway($0) }) {
            return .missingGateway(tool: trimmed)
        }
        if let owned = serverOwning(tool: trimmed, servers: servers, advertised: advertised) {
            if let promo = promoted.values.first(where: {
                $0.serverId == owned.server.id
                    && ($0.executeTool == owned.tool || $0.chatName == owned.tool
                        || $0.chatName == McpNativeNaming.chatName(server: owned.server, tool: owned.tool))
            }) {
                return .promoted(promo)
            }
            return .advertised(serverId: owned.server.id, toolName: owned.tool)
        }
        return nil
    }

    public static func missingGatewayMessage(tool: String, enabled: [McpServer]) -> String {
        let names = enabled.map(\.name).joined(separator: ", ")
        let available = names.isEmpty ? "none" : names
        return """
        \(tool) is a Toolport/gateway meta-tool, but Toolport is not enabled. \
        Available MCP servers: \(available). Call first-class tools already in your list \
        (names like server__tool), or mcp_call with server=<one of those names> and \
        tool=<a name from mcp_list_tools>. Do not invent Toolport catalog names.
        """
    }

    public static func preferredRoute(for builtin: String, context: McpFallbackContext) -> String? {
        guard context.hasMcp else { return nil }
        let analog = analogTool(for: builtin)
        if let named = context.firstClassNames.first(where: {
            $0.lowercased().hasSuffix(McpNativeNaming.separator + analog)
                || $0.lowercased().hasSuffix("_" + analog)
        }) {
            return "Call \(named) with the same arguments."
        }
        if let server = preferredServer(for: builtin, context: context) {
            let known = context.advertised[server.id] ?? []
            let tool = canonicalTool(analog, known: known)
                ?? known.first { $0.lowercased().contains(analog.replacingOccurrences(of: "_", with: "")) }
                ?? analog
            let chat = "\(McpNativeNaming.slug(asServer(server)))\(McpNativeNaming.separator)\(tool)"
            return "mcp_call server=\(server.name) tool=\(tool) (or call \(chat) if it is in your tool list) with the same arguments."
        }
        let names = context.serverNames.joined(separator: ", ")
        return "mcp_call with server=<one of: \(names)> and the matching tool from mcp_list_tools. Do not call Toolport unless that name is listed."
    }

    public static func preferredServer(for builtin: String, context: McpFallbackContext) -> McpServerRef? {
        let needles: [String]
        switch builtin {
        case "write_file", "edit_file", "read_file", "list_files", "delete_file", "move_file":
            needles = ["fast-filesystem", "filesystem", "files", "fs"]
        case "web_search":
            needles = ["ddg", "duck", "search", "brave", "firecrawl"]
        case "web_fetch":
            needles = ["firecrawl", "fetch", "ddg", "duck", "search"]
        case "shell":
            needles = ["macuse", "shell"]
        case "destination_write":
            needles = ["obsidian", "vault"]
        default:
            needles = []
        }
        for needle in needles {
            let hits = context.servers.filter {
                $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle)
            }
            if hits.count == 1 { return hits[0] }
            if let first = hits.first { return first }
        }
        if context.hasGateway {
            return context.servers.first(where: \.isGateway)
        }
        return nil
    }

    // MARK: - Private

    private static func analogTool(for builtin: String) -> String {
        switch builtin {
        case "list_files": return "list_directory"
        case "web_search": return "search"
        case "web_fetch": return "fetch_content"
        case "destination_write": return "obsidian_put_file"
        default: return builtin
        }
    }

    private static func asServer(_ ref: McpServerRef) -> McpServer {
        McpServer(id: ref.id, name: ref.name)
    }

    private static func stripDecor(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = trimmed.firstIndex(of: "[") {
            trimmed = String(trimmed[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func uniqueMatch(_ needle: String, in servers: [McpServer]) -> McpServer? {
        let hits = servers.filter { server in
            server.id.lowercased() == needle
                || server.name.lowercased() == needle
                || server.toolId.lowercased() == needle
                || server.toolId.lowercased() == "mcp:\(needle)"
                || McpNativeNaming.slug(server) == needle
        }
        return hits.count == 1 ? hits[0] : nil
    }

    private static func firstTokenMatch(
        _ name: String,
        server: McpServer,
        known: [String]
    ) -> (McpServer, String)? {
        let slug = McpNativeNaming.slug(server)
        let token = slug.split(separator: "-").first.map(String.init) ?? slug
        guard token.count >= 3, name.lowercased().hasPrefix(token + "_") else { return nil }
        let rest = String(name.dropFirst(token.count + 1))
        guard !rest.isEmpty else { return nil }
        if let tool = canonicalTool(rest, known: known) {
            return (server, tool)
        }
        if known.isEmpty { return (server, rest) }
        return nil
    }

    private static func uniqued(_ hits: [(McpServer, String)]) -> [(McpServer, String)] {
        var seen = Set<String>()
        var out: [(McpServer, String)] = []
        for hit in hits {
            let key = hit.0.id + "/" + hit.1
            if seen.insert(key).inserted { out.append(hit) }
        }
        return out
    }

    private static func needServerMessage(enabled: [McpServer]) -> String {
        let names = enabled.map(\.name).joined(separator: ", ")
        let example = enabled.first?.name ?? "the server name"
        return """
        mcp_list_tools / mcp_call need server=\(example) when more than one MCP is enabled. \
        Available: \(names). Pass server by name. Never omit server, and do not assume Toolport \
        unless that name is listed. First-class tools already in your list can be called directly.
        """
    }

    private static func unknownServerMessage(requested: String, enabled: [McpServer]) -> String {
        let names = enabled.map(\.name).joined(separator: ", ")
        let example = enabled.first?.name ?? "the server name"
        if McpGatewayCall.isMetaTool(requested) || requested.lowercased().contains("toolport") {
            return """
            MCP server '\(requested)' is not enabled. Available: \(names). \
            Pass server by name (e.g. \(example)). Do not call Toolport unless it is listed.
            """
        }
        return "Unknown or disabled MCP server '\(requested)'. Available: \(names). Pass server by name (e.g. \(example))."
    }
}
