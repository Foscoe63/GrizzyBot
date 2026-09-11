import Foundation
@testable import GrizzyBotCore
import Testing

@Suite("McpToolGate")
struct McpToolGateTests {
    @Test("child ids round-trip")
    func childIds() throws {
        let id = McpToolGate.childId(serverId: "abc", toolName: "read_file")
        #expect(id == "mcp:abc/read_file")
        let parsed = try #require(McpToolGate.parse(id))
        #expect(parsed.serverId == "abc")
        #expect(parsed.toolName == "read_file")
        #expect(McpToolGate.parse("mcp:abc") == nil)
        #expect(McpToolGate.parse("write_file") == nil)
        #expect(McpToolGate.parse("mcp:abc/github__search")?.toolName == "github__search")
    }

    @Test("legacy parent-only enablement keeps every advertised tool on")
    func legacyAllOn() {
        let enabled = ["mcp:srv"]
        #expect(McpToolGate.isToolEnabled(enabledIds: enabled, serverId: "srv", toolName: "read_file", advertised: ["read_file"]))
        #expect(!McpToolGate.isToolEnabled(enabledIds: [], serverId: "srv", toolName: "read_file", advertised: ["read_file"]))
    }

    @Test("explicit child off denies advertised tools and leaves unknown catalog names on")
    func childOff() {
        var ids = ["mcp:srv"]
        McpToolGate.setChild(
            enabledIds: &ids,
            serverId: "srv",
            toolName: "write_file",
            enabled: false,
            advertised: ["read_file", "write_file"]
        )
        #expect(ids.contains("mcp:srv/read_file"))
        #expect(!ids.contains("mcp:srv/write_file"))
        #expect(McpToolGate.isToolEnabled(enabledIds: ids, serverId: "srv", toolName: "read_file", advertised: ["read_file", "write_file"]))
        #expect(!McpToolGate.isToolEnabled(enabledIds: ids, serverId: "srv", toolName: "write_file", advertised: ["read_file", "write_file"]))
        #expect(McpToolGate.isToolEnabled(
            enabledIds: ids,
            serverId: "srv",
            toolName: "github__search_repositories",
            advertised: ["read_file", "write_file"]
        ))
    }

    @Test("enabling a child turns the parent on")
    func childEnablesParent() {
        var ids: [String] = []
        McpToolGate.setChild(
            enabledIds: &ids,
            serverId: "srv",
            toolName: "read_file",
            enabled: true,
            advertised: ["read_file"]
        )
        #expect(ids.contains("mcp:srv"))
        #expect(ids.contains("mcp:srv/read_file"))
    }

    @Test("stripServer removes parent and children")
    func strip() {
        var ids = ["write_file", "mcp:srv", "mcp:srv/read_file", "mcp:other/x"]
        McpToolGate.stripServer("srv", from: &ids)
        #expect(ids == ["write_file", "mcp:other/x"])
    }
}

@Suite("MCP per-tool store")
@MainActor
struct McpPerToolStoreTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        return store
    }

    @Test("defaults and bots keep per-tool MCP toggles; delete strips children")
    func childTogglesAndDelete() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "mcp-tools@b.com", password: "password1") == nil)
        let server = try #require(store.addMcpServer(
            name: "filesystem",
            transport: .stdio,
            command: "npx",
            args: ["-y", "fake"],
            env: [:],
            url: "",
            headers: [:]
        ))
        let bot = store.createBot(name: "Bot")
        store.mcpAdvertisedTools[server.id] = ["read_file", "write_file"]
        store.setDefaultMcpChildTool(serverId: server.id, toolName: "write_file", enabled: false)
        #expect(store.isDefaultMcpToolEnabled(serverId: server.id, toolName: "read_file"))
        #expect(!store.isDefaultMcpToolEnabled(serverId: server.id, toolName: "write_file"))

        store.setBotMcpChildTool(botId: bot.id, serverId: server.id, toolName: "read_file", enabled: false)
        #expect(!store.isBotMcpToolEnabled(botId: bot.id, serverId: server.id, toolName: "read_file"))
        #expect(store.isBotMcpToolEnabled(botId: bot.id, serverId: server.id, toolName: "write_file"))

        let child = McpToolGate.childId(serverId: server.id, toolName: "read_file")
        #expect(store.knownToolIds.contains(child))
        store.deleteMcpServer(server.id)
        #expect(!store.appConfig.defaultEnabledTools.contains { $0.hasPrefix("mcp:\(server.id)") })
        #expect(store.bots.allSatisfy { bot in
            !bot.enabledTools.contains { $0.hasPrefix("mcp:\(server.id)") }
        })
        #expect(store.mcpAdvertisedTools[server.id] == nil)
    }

    @Test("cached advertised names count as connected until a live probe runs")
    func cachedStatus() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "mcp-status@b.com", password: "password1") == nil)
        let server = try #require(store.addMcpServer(
            name: "fs",
            transport: .stdio,
            command: "npx",
            args: [],
            env: [:],
            url: "",
            headers: [:]
        ))
        #expect(store.mcpStatus(for: server.id) == .idle)
        store.mcpAdvertisedTools[server.id] = ["a", "b", "c"]
        #expect(store.mcpStatus(for: server.id) == .connected(toolCount: 3))
        #expect(store.mcpToolNames(for: server.id) == ["a", "b", "c"])
    }

    @Test("mcpToolNames does not list namespaced aliases next to the real tool")
    func mcpToolNamesNoAliasDouble() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "mcp-dup@b.com", password: "password1") == nil)
        let server = try #require(store.addMcpServer(
            name: "firecrawl-mcp",
            transport: .stdio,
            command: "npx",
            args: [],
            env: [:],
            url: "",
            headers: [:]
        ))
        store.mcpAdvertisedTools[server.id] = [
            "firecrawl_scrape",
            "firecrawl-mcp__firecrawl_scrape",
            "firecrawl_map",
        ]
        store.mcpPromotedTools["firecrawl-mcp__firecrawl_scrape"] = McpPromotedTool(
            chatName: "firecrawl-mcp__firecrawl_scrape",
            serverId: server.id,
            executeTool: "firecrawl_scrape"
        )
        #expect(store.mcpToolNames(for: server.id) == ["firecrawl_map", "firecrawl_scrape"])
    }

    @Test("disabled default tools stay off across opt-in and reload")
    func disabledDefaultsPersist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.signUp(name: "A", email: "defaults@b.com", password: "password1") == nil)
        store.setDefaultTool("write_file", enabled: false)
        store.setDefaultTools(["web_search", "shell"], enabled: false)
        #expect(!store.appConfig.defaultEnabledTools.contains("write_file"))
        #expect(!store.appConfig.defaultEnabledTools.contains("shell"))
        #expect(store.optInNewTool("write_file") == false)
        #expect(store.optInNewTool("shell") == false)
        #expect(!store.appConfig.defaultEnabledTools.contains("write_file"))
        #expect(!store.appConfig.defaultEnabledTools.contains("shell"))

        let reloaded = AppStore(dataDirectory: dir, delayScale: 0.01)
        reloaded.pluginClient = AlwaysAllowPlugins()
        #expect(!reloaded.appConfig.defaultEnabledTools.contains("write_file"))
        #expect(!reloaded.appConfig.defaultEnabledTools.contains("web_search"))
        #expect(!reloaded.appConfig.defaultEnabledTools.contains("shell"))
        #expect(reloaded.appConfig.defaultEnabledTools.contains("read_file"))
    }

    @Test("opt-in still adds a brand-new tool id")
    func newToolStillOptedIn() throws {
        let store = tempStore()
        #expect(store.signUp(name: "A", email: "newtool@b.com", password: "password1") == nil)
        #expect(store.optInNewTool("brand_new_tool") == true)
        #expect(store.appConfig.defaultEnabledTools.contains("brand_new_tool"))
        #expect(store.optInNewTool("brand_new_tool") == false)
    }
}
