import Foundation
import Observation

// MCP server lookup, advertised/promoted tools, and catalog warming.
extension AppStore {
    func enabledMcpServers(bot: Bot) -> [McpServer] {
        mcpServers.filter { bot.isToolEnabled($0.toolId) }
    }

    func advertisedMcpTools(for bot: Bot) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for server in enabledMcpServers(bot: bot) {
            let names = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[server.id] ?? [])
            let allowed = names.filter {
                McpToolGate.isToolEnabled(
                    enabledIds: bot.enabledTools,
                    serverId: server.id,
                    toolName: $0,
                    advertised: names
                )
            }
            if !allowed.isEmpty {
                out[server.id] = allowed
            }
        }
        return out
    }

    func promotedMcpTools(for bot: Bot) -> [McpPromotedTool] {
        mcpPromotedTools.values.filter { promo in
            let advertised = mcpToolNames(for: promo.serverId)
            return McpToolGate.isToolEnabled(
                enabledIds: bot.enabledTools,
                serverId: promo.serverId,
                toolName: promo.chatName,
                advertised: advertised
            )
        }
    }

    func mcpToolDisabledMessage(
        bot: Bot,
        server: McpServer,
        toolName: String,
        raw: [String: JSONValue]
    ) -> String? {
        let prepared = McpGatewayCall.prepare(server: server, toolName: toolName, raw: raw)
        let catalog = McpGatewayCall.catalogToolName(prepared)
        let advertised = mcpToolNames(for: server.id)
        let names = Set([toolName, catalog].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for name in names {
            if !McpToolGate.isToolEnabled(
                enabledIds: bot.enabledTools,
                serverId: server.id,
                toolName: name,
                advertised: advertised
            ) {
                return "MCP tool \(name) is turned off for this bot on \(server.name). Enable it under Tools."
            }
        }
        return nil
    }

    func resolveMcpServer(_ raw: String, toolName: String = "", bot: Bot) -> McpServer? {
        switch McpToolRouting.resolveServer(
            requested: raw,
            toolName: toolName,
            enabled: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        ) {
        case .resolved(let server):
            return server
        case .failed:
            return nil
        }
    }

    func mcpServerResolveError(requested: String, toolName: String = "", bot: Bot) -> String {
        switch McpToolRouting.resolveServer(
            requested: requested,
            toolName: toolName,
            enabled: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        ) {
        case .resolved:
            return "Unknown or disabled MCP server '\(requested)'."
        case .failed(let message):
            return message
        }
    }

    func rememberPromoted(_ tools: [McpPromotedTool], serverId: String) {
        guard !tools.isEmpty else { return }
        mcpPromotedTools = McpCatalogPromote.merge(existing: mcpPromotedTools, adding: tools)
        var advertised = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[serverId] ?? [])
        for tool in tools where !McpCatalogPromote.isDispatcher(tool.executeTool) {
            if !advertised.contains(tool.executeTool) { advertised.append(tool.executeTool) }
        }
        mcpAdvertisedTools[serverId] = McpCatalogPromote.uniqueAdvertisedNames(advertised)
    }

    @discardableResult
    func applyMcpList(serverId: String, tools: [McpToolInfo]) -> [McpPromotedTool] {
        let names = McpCatalogPromote.uniqueAdvertisedNames(tools.map(\.name))
        mcpAdvertisedTools[serverId] = names
        mcpListedTools[serverId] = tools
        mcpProbeStatus[serverId] = .connected(toolCount: names.count)
        let server = mcpServers.first(where: { $0.id == serverId })
            ?? McpServer(id: serverId, name: serverId)
        let harvested = McpCatalogPromote.fromListed(server: server, tools: tools)
        rememberPromoted(harvested, serverId: serverId)
        optInMcpChildTools(serverId: serverId, names: names)
        save()
        return harvested
    }

    func optInMcpChildTools(serverId: String, names: [String]) {
        for name in names {
            optInNewTool(McpToolGate.childId(serverId: serverId, toolName: name))
        }
    }

    @discardableResult
    func rememberHarvest(serverId: String, catalogTool: String, text: String) -> [McpPromotedTool] {
        let harvested = McpCatalogPromote.harvest(
            serverId: serverId,
            catalogTool: catalogTool,
            text: text
        )
        rememberPromoted(harvested, serverId: serverId)
        return harvested
    }

    func hydratePromotedFromAdvertised(bot: Bot) {
        let stubs = McpCatalogPromote.fromAdvertised(
            servers: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        )
        mcpPromotedTools = McpCatalogPromote.merge(existing: mcpPromotedTools, adding: stubs)
        for serverId in Set(stubs.map(\.serverId)) {
            if let names = mcpAdvertisedTools[serverId] {
                mcpAdvertisedTools[serverId] = McpCatalogPromote.uniqueAdvertisedNames(names)
            }
        }
    }

    /// Prefetch Toolport catalog matches from the user prompt so Gmail/MacUse tools are first-class on step 1.
    func warmMcpCatalog(bot: Bot, prompt: String) async {
        let enabled = enabledMcpServers(bot: bot)
        let queries = McpCatalogPromote.warmQueries(from: prompt)
        if let gateway = enabled.first(where: { McpGatewayCall.isGateway($0) }) {
            for item in queries {
                var args: [String: JSONValue] = ["query": .string(item.query)]
                if let filter = item.server {
                    args["server"] = .string(filter)
                }
                let prepared = McpGatewayCall.prepare(
                    server: gateway,
                    toolName: "toolport_search_tools",
                    raw: ["tool": .string("toolport_search_tools"), "arguments": .object(args)]
                )
                guard let result = try? await McpClient.call(
                    server: gateway,
                    toolName: prepared.toolName,
                    arguments: prepared.arguments
                ), !McpGatewayCall.failed(isError: result.isError, text: result.text)
                else { continue }
                rememberHarvest(serverId: gateway.id, catalogTool: "toolport_search_tools", text: result.text)
            }
        }

        let lower = prompt.lowercased()
        let wantsMail = lower.contains("gmail") || lower.contains("email") || lower.contains("inbox")
            || lower.contains("macuse")
        guard wantsMail else { return }
        let server = enabled.first { $0.name.lowercased().contains("macuse") }
            ?? enabled.first(where: { McpGatewayCall.isGateway($0) })
        guard let server else { return }
        let mailNames: [JSONValue] = [
            .string("mail_list_accounts"),
            .string("mail_list_mailboxes"),
            .string("mail_search_messages"),
            .string("mail_get_messages"),
            .string("mail_get_message"),
        ]
        let defsPrepared = McpGatewayCall.prepare(
            server: server,
            toolName: "macuse__get_tool_definitions",
            raw: [
                "tool": .string("macuse__get_tool_definitions"),
                "arguments": .object(["names": .array(mailNames)]),
            ]
        )
        guard let defs = try? await McpClient.call(
            server: server,
            toolName: defsPrepared.toolName,
            arguments: defsPrepared.arguments
        ), !McpGatewayCall.failed(isError: defs.isError, text: defs.text)
        else { return }
        rememberHarvest(
            serverId: server.id,
            catalogTool: "macuse__get_tool_definitions",
            text: defs.text
        )
    }
}
