import Foundation
import GrizzyBotCore
import Testing

@Suite("McpCatalogPromote")
struct McpCatalogPromoteTests {
    @Test("harvests Toolport search backtick catalog names")
    func harvestSearch() {
        let text = """
        Found 11 matching tool(s) on "gmail". Top match: `gmail__messages_list`. \
        Also see `gmail__get_profile` and toolport_call_tool.
        """
        let tools = McpCatalogPromote.harvestSearch(serverId: "tp", text: text)
        let names = Set(tools.map(\.chatName))
        #expect(names.contains("gmail__messages_list"))
        #expect(names.contains("gmail__get_profile"))
        #expect(!names.contains("toolport_call_tool"))
        #expect(tools.allSatisfy { $0.executeTool == $0.chatName && $0.injectName == nil })
    }

    @Test("harvests MacUse definitions into call_tool_by_name dispatch")
    func harvestDefinitions() {
        let json = """
        {"tools":[{"name":"mail_search_messages","description":"Search mail","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}
        """
        let tools = McpCatalogPromote.harvestDefinitions(
            serverId: "tp",
            catalogTool: "macuse__get_tool_definitions",
            text: json
        )
        #expect(tools.count == 1)
        let tool = tools[0]
        #expect(tool.chatName == "macuse__mail_search_messages")
        #expect(tool.executeTool == "macuse__call_tool_by_name")
        #expect(tool.injectName == "mail_search_messages")
        #expect(tool.description.contains("Search mail"))
    }

    @Test("mcpCallArguments injects name for MacUse dispatch")
    func mcpCallArgs() {
        let promoted = McpPromotedTool(
            chatName: "macuse__mail_search_messages",
            serverId: "tp",
            executeTool: "macuse__call_tool_by_name",
            injectName: "mail_search_messages"
        )
        let args = McpCatalogPromote.mcpCallArguments(
            promoted: promoted,
            raw: ["query": .string("from:boss"), "mailbox": .string("INBOX")]
        )
        #expect(args["tool"] == .string("macuse__call_tool_by_name"))
        #expect(args["server"] == .string("tp"))
        #expect(args["name"] == .string("mail_search_messages"))
        let inner = args["arguments"]?.objectValue() ?? [:]
        #expect(inner["name"] == .string("mail_search_messages"))
        #expect(inner["query"] == .string("from:boss"))
    }

    @Test("chatTools include promoted catalog tools")
    func chatToolsIncludePromoted() {
        let promoted = McpPromotedTool(
            chatName: "gmail__messages_list",
            serverId: "tp",
            executeTool: "gmail__messages_list",
            description: "List Gmail messages"
        )
        let server = McpServer(id: "tp", name: "Toolport", command: "toolport-gateway")
        let tools = AgentToolCatalog.chatTools(
            enabledIds: [server.toolId],
            mcpServers: [server],
            promotedMcp: [promoted]
        )
        let names = Set(tools.map(\.function.name))
        #expect(names.contains("mcp_call"))
        #expect(names.contains("gmail__messages_list"))
    }

    @Test("chatTools omit promoted tools that are toggled off")
    func chatToolsOmitDisabledPromoted() {
        let promoted = McpPromotedTool(
            chatName: "gmail__messages_list",
            serverId: "tp",
            executeTool: "gmail__messages_list",
            description: "List Gmail messages"
        )
        let server = McpServer(id: "tp", name: "Toolport", command: "toolport-gateway")
        let other = McpToolGate.childId(serverId: "tp", toolName: "toolport_search_tools")
        let tools = AgentToolCatalog.chatTools(
            enabledIds: [server.toolId, other],
            mcpServers: [server],
            promotedMcp: [promoted],
            mcpAdvertised: ["tp": ["gmail__messages_list", "toolport_search_tools"]]
        )
        let names = Set(tools.map(\.function.name))
        #expect(names.contains("mcp_call"))
        #expect(!names.contains("gmail__messages_list"))
    }

    @Test("fromListed namespaces colliding tool names")
    func fromListedNamespaces() {
        let server = McpServer(id: "fs", name: "fast-filesystem", command: "npx")
        let tools = McpCatalogPromote.fromListed(
            server: server,
            tools: [
                McpToolInfo(name: "write_file", description: "Write a file"),
                McpToolInfo(name: "toolport_search_tools", description: "meta"),
            ]
        )
        #expect(tools.map(\.chatName) == ["fast-filesystem__write_file"])
        #expect(tools[0].executeTool == "write_file")
    }

    @Test("chatTools expose advertised MCP tools as first-class namespaced functions")
    func chatToolsFromAdvertised() {
        let server = McpServer(id: "fs", name: "fast-filesystem", command: "npx")
        let tools = AgentToolCatalog.chatTools(
            enabledIds: [server.toolId],
            mcpServers: [server],
            mcpAdvertised: ["fs": ["write_file", "read_file"]]
        )
        let names = Set(tools.map(\.function.name))
        #expect(names.contains("fast-filesystem__write_file"))
        #expect(names.contains("fast-filesystem__read_file"))
        #expect(names.contains("mcp_call"))
        #expect(!names.contains("write_file"))
    }

    @Test("uniqueAdvertisedNames drops namespaced aliases")
    func uniqueAdvertisedDropsAliases() {
        let names = McpCatalogPromote.uniqueAdvertisedNames([
            "firecrawl_scrape",
            "firecrawl_scrape",
            "firecrawl-mcp__firecrawl_scrape",
            "firecrawl_map",
        ])
        #expect(names == ["firecrawl_scrape", "firecrawl_map"])
        let catalog = McpCatalogPromote.uniqueAdvertisedNames(["gmail__messages_list", "gmail__get_profile"])
        #expect(catalog.contains("gmail__messages_list"))
        #expect(catalog.contains("gmail__get_profile"))
    }

    @Test("merge collapses raw and namespaced copies of the same tool")
    func mergeCollapsesAlias() {
        let raw = McpPromotedTool(
            chatName: "firecrawl_scrape",
            serverId: "fc",
            executeTool: "firecrawl_scrape",
            description: "thin"
        )
        let named = McpPromotedTool(
            chatName: "firecrawl-mcp__firecrawl_scrape",
            serverId: "fc",
            executeTool: "firecrawl_scrape",
            description: "Scrape a URL",
            inputSchema: ["properties": AnyCodableMCP(["url": ["type": "string"]])]
        )
        let merged = McpCatalogPromote.merge(existing: ["firecrawl_scrape": raw], adding: [named])
        #expect(merged.count == 1)
        #expect(merged["firecrawl-mcp__firecrawl_scrape"] != nil)
        #expect(merged["firecrawl_scrape"] == nil)
    }

    @Test("chatTools do not emit both raw and namespaced names")
    func chatToolsNoDoubles() {
        let server = McpServer(id: "fc", name: "firecrawl-mcp", command: "npx")
        let promoted = McpPromotedTool(
            chatName: "firecrawl_scrape",
            serverId: "fc",
            executeTool: "firecrawl_scrape"
        )
        let tools = AgentToolCatalog.chatTools(
            enabledIds: [server.toolId],
            mcpServers: [server],
            promotedMcp: [promoted],
            mcpAdvertised: ["fc": ["firecrawl_scrape", "firecrawl-mcp__firecrawl_scrape"]]
        )
        let firecrawl = tools.map(\.function.name).filter { $0.contains("scrape") || $0.contains("firecrawl") }
        #expect(firecrawl.count == 1)
        #expect(firecrawl.first == "firecrawl-mcp__firecrawl_scrape")
    }

    @Test("warmQueries picks gmail and macuse from prompt")
    func warmQueries() {
        let q = McpCatalogPromote.warmQueries(from: "Use the mcp-server Gmail that is hosted by toolport")
        #expect(q.contains(where: { $0.query == "gmail" }))
    }
}
