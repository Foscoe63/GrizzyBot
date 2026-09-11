import Foundation
import GrizzyBotCore
import Testing

@Suite("McpToolRouting")
struct McpToolRoutingTests {
    private let macuse = McpServer(id: "mu", name: "MacUse", command: "npx")
    private let ddg = McpServer(id: "ddg", name: "ddg-search", command: "npx")
    private let files = McpServer(id: "fs", name: "fast-filesystem", command: "npx")
    private let firecrawl = McpServer(id: "fc", name: "firecrawl-mcp", command: "npx")

    private var fleet: [McpServer] { [macuse, ddg, files, firecrawl] }

    private var advertised: [String: [String]] {
        [
            "mu": ["get_tool_definitions", "call_tool_by_name"],
            "ddg": ["search"],
            "fs": ["write_file", "read_file", "list_directory"],
            "fc": ["firecrawl_scrape", "fetch_content"],
        ]
    }

    @Test("omit server with many MCPs does not pick MacUse")
    func omitServerRequiresName() {
        switch McpToolRouting.resolveServer(requested: "", enabled: fleet, advertised: advertised) {
        case .resolved:
            Issue.record("should not default to the first MCP")
        case .failed(let message):
            #expect(message.contains("MacUse"))
            #expect(message.contains("fast-filesystem"))
            #expect(message.contains("Never omit server"))
            #expect(!message.lowercased().contains("omit server when only one"))
        }
    }

    @Test("omit server resolves unique advertised tool")
    func omitServerFindsFilesystemWrite() {
        switch McpToolRouting.resolveServer(
            requested: "",
            toolName: "write_file",
            enabled: fleet,
            advertised: advertised
        ) {
        case .resolved(let server):
            #expect(server.id == "fs")
        case .failed(let message):
            Issue.record("expected resolve, got \(message)")
        }
    }

    @Test("namespaced and fast_write_file map to fast-filesystem")
    func identityAliases() {
        #expect(McpNativeNaming.chatName(server: files, tool: "write_file") == "fast-filesystem__write_file")
        let owned = McpToolRouting.serverOwning(
            tool: "fast_write_file",
            servers: fleet,
            advertised: advertised
        )
        #expect(owned?.server.id == "fs")
        #expect(owned?.tool == "write_file")
        let split = McpToolRouting.serverOwning(
            tool: "fast-filesystem__write_file",
            servers: fleet,
            advertised: advertised
        )
        #expect(split?.server.id == "fs")
    }

    @Test("unknown Toolport server names the real list")
    func unknownToolport() {
        switch McpToolRouting.resolveServer(
            requested: "Toolport",
            toolName: "toolport_search_tools",
            enabled: fleet,
            advertised: advertised
        ) {
        case .resolved:
            Issue.record("Toolport is not enabled")
        case .failed(let message):
            #expect(message.contains("not enabled"))
            #expect(message.contains("MacUse"))
            #expect(message.contains("Do not call Toolport"))
        }
    }

    @Test("toolport meta-tool without a gateway is a miss")
    func missingGatewayDirect() {
        let hit = McpToolRouting.resolveDirectTool(
            name: "toolport_search_tools",
            promoted: [:],
            servers: fleet,
            advertised: advertised
        )
        #expect(hit == .missingGateway(tool: "toolport_search_tools"))
        let message = McpToolRouting.missingGatewayMessage(tool: "toolport_search_tools", enabled: fleet)
        #expect(message.contains("not enabled"))
        #expect(message.contains("fast-filesystem"))
    }

    @Test("single MCP still allows omitting server")
    func singleServerOmit() {
        switch McpToolRouting.resolveServer(requested: "", toolName: "", enabled: [files]) {
        case .resolved(let server):
            #expect(server.id == "fs")
        case .failed(let message):
            Issue.record("expected resolve, got \(message)")
        }
    }

    @Test("mcp_call description lists servers for fallback context")
    func parseServerList() {
        let tools = AgentToolCatalog.chatTools(
            enabledIds: fleet.map(\.toolId),
            mcpServers: fleet
        )
        let call = tools.first { $0.function.name == "mcp_call" }
        let listed = McpToolRouting.parseServerList(from: call?.function.description ?? "")
        #expect(listed.contains("MacUse"))
        #expect(listed.contains("fast-filesystem"))
        #expect(call?.function.description.contains("Always pass server") == true)
        #expect(call?.function.description.lowercased().contains("omit server to use toolport") != true)
    }
}
