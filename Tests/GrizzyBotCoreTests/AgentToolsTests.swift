import Foundation
import GrizzyBotCore
import Testing

@Suite("AgentTools")
struct AgentToolsTests {
    @Test("catalog covers every scripted action")
    func catalogCoverage() {
        let ids = Set(AgentToolCatalog.allIds)
        let samples: [ScriptedAction] = [
            .writeFile(path: "a", content: "b"),
            .readFile(path: "a"),
            .editFile(path: "a", content: "b", append: false),
            .moveFile(from: "a", to: "b"),
            .deleteFile(path: "a"),
            .listFiles(directory: ""),
            .webSearch(query: "q"),
            .remember(text: "x"),
            .takeover(reason: "r"),
            .spawnBot(name: "N", title: "T"),
            .deleteBot(name: "N"),
            .subagent(task: "t"),
            .destinationWrite(title: "t", body: "b"),
            .customTool(id: "custom-1", name: "Custom"),
            .mcpServer(id: "srv-1", name: "filesystem", prompt: "list files"),
        ]
        for action in samples {
            switch action {
            case .customTool:
                #expect(action.toolId == "custom-1")
            case .mcpServer:
                #expect(action.toolId == "mcp:srv-1")
            default:
                #expect(ids.contains(action.toolId))
            }
        }
        #expect(ids.contains("shell"))
    }

    @Test("custom tool phrase match")
    func customMatch() {
        let tool = CustomAgentTool(
            name: "Inbox triage",
            triggers: ["triage inbox"],
            responseTemplate: "triaged: {prompt}"
        )
        let reply = ScriptedRuntime.reply(to: "please triage inbox now", customTools: [tool])
        #expect(reply.action == .customTool(id: tool.id, name: "Inbox triage"))
        #expect(reply.text.contains("triaged:"))
    }

    @Test("mcp server name match")
    func mcpMatch() {
        let server = McpServer(
            name: "filesystem",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        )
        let reply = ScriptedRuntime.reply(to: "use mcp filesystem to list /tmp", mcpServers: [server])
        #expect(reply.action == .mcpServer(id: server.id, name: "filesystem", prompt: "use mcp filesystem to list /tmp"))
        #expect(reply.text.contains("filesystem"))
        #expect(AgentToolCatalog.allIds(mcpServers: [server]).contains(server.toolId))
        #expect(server.definition.kind == .mcp)
    }

    @Test("bot tool toggles")
    func botToggles() {
        var bot = Bot(id: "1", name: "A", color: "#fff", threadId: "t")
        #expect(bot.allToolsEnabled)
        bot.setTool("web_search", enabled: false)
        #expect(!bot.isToolEnabled("web_search"))
        #expect(bot.isToolEnabled("write_file"))
        #expect(bot.isToolEnabled("forget"))
        bot.setAllTools(enabled: false)
        #expect(bot.noToolsEnabled)
        bot.setAllTools(enabled: true)
        #expect(bot.allToolsEnabled)
    }

    @Test("MCP env and header text round-trips")
    func mcpConfigText() {
        let env = McpConfigText.parseEnv(" API_KEY=abc \nEMPTY=\n# skip\nPATH=/usr/bin")
        #expect(env["API_KEY"] == "abc")
        #expect(env["EMPTY"] == "")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["# skip"] == nil)
        #expect(McpConfigText.envLines(["B": "2", "A": "1"]) == "A=1\nB=2")

        let headers = McpConfigText.parseHeaders("Authorization: Bearer x\nX-Foo: bar")
        #expect(headers["Authorization"] == "Bearer x")
        #expect(headers["X-Foo"] == "bar")
        #expect(McpConfigText.headerLines(["Z": "9", "A": "1"]) == "A: 1\nZ: 9")
        #expect(McpConfigText.parseArgs(" -y  @pkg  /tmp ") == ["-y", "@pkg", "/tmp"])
        #expect(McpConfigText.argsLine(["-y", "@pkg"]) == "-y @pkg")
    }
}
