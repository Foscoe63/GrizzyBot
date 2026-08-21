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

    @Test("warmQueries picks gmail and macuse from prompt")
    func warmQueries() {
        let q = McpCatalogPromote.warmQueries(from: "Use the mcp-server Gmail that is hosted by toolport")
        #expect(q.contains(where: { $0.query == "gmail" }))
    }
}
