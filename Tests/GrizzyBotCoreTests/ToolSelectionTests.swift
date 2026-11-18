import Foundation
import GrizzyBotCore
import Testing

@Suite("Tool selection")
@MainActor
struct ToolSelectionTests {
    private func tool(_ name: String, _ description: String = "") -> ChatTool {
        ChatTool(function: ChatToolFunction(name: name, description: description, parameters: .object([:])))
    }

    private var catalog: [ChatTool] {
        [
            tool("read_file", "Read a UTF-8 file from the working folder"),
            tool("write_file", "Write a UTF-8 file"),
            tool("web_search", "Search the public web for current facts"),
            tool("send_email", "Send an email message"),
            tool("gmail__messages_list", "List Gmail messages"),
            tool("slack__post", "Post to a Slack channel"),
            tool("todo", "Write a checklist"),
            tool("complete", "Finish the task"),
        ]
    }

    @Test("selectors parse, and bad ones are refused")
    func parsing() {
        #expect(ToolSelection.parse("*") == .everything)
        #expect(ToolSelection.parse("builtin:*") == .allBuiltin)
        #expect(ToolSelection.parse("mcp:*") == .allMcp)
        #expect(ToolSelection.parse("mcp:gmail:*") == .mcpServer("gmail"))
        #expect(ToolSelection.parse("mcp:gmail:send") == .mcpTool(server: "gmail", tool: "send"))
        #expect(ToolSelection.parse("read_file") == .builtin("read_file"))
        for bad in ["", "read*", "mcp:gm*:send", "mcp:gmail", "mcp::x", "mcp:a:b:c", "two words", "a:b"] {
            #expect(ToolSelection.parse(bad) == nil, "\(bad)")
        }
        let lines = ToolSelection.parseLines("read_file\n# comment\n\nread_file\nread*\nmcp:slack:*")
        #expect(lines.selectors == ["read_file", "mcp:slack:*"])
        #expect(lines.invalid == ["read*"])
    }

    @Test("the default selection changes nothing")
    func defaultIsIdentity() {
        let selection = ToolSelection()
        #expect(selection.isDefault)
        let applied = selection.apply(to: catalog, prompt: "anything")
        #expect(applied.offered == catalog)
        #expect(applied.deferred.isEmpty)
    }

    @Test("allow-only offers just the listed tools, plus the loop's own")
    func allowOnly() {
        let selection = ToolSelection(allowOnly: true, allow: ["read_file", "mcp:gmail:*"])
        let names = selection.apply(to: catalog, prompt: "").offered.map(\.function.name)
        #expect(names == ["read_file", "gmail__messages_list", "todo", "complete"])
    }

    @Test("an empty allow list selects no tools, but never strips the loop's own")
    func emptyAllow() {
        let names = ToolSelection(allowOnly: true).apply(to: catalog, prompt: "").offered.map(\.function.name)
        #expect(names == ["todo", "complete"])
    }

    @Test("exclude wins over allow, and cannot remove the loop's own tools")
    func excludeWins() {
        let selection = ToolSelection(allowOnly: true, allow: ["builtin:*"], exclude: ["write_file", "todo", "complete"])
        let names = selection.apply(to: catalog, prompt: "").offered.map(\.function.name)
        #expect(!names.contains("write_file"))
        #expect(names.contains("read_file"))
        #expect(names.contains("todo") && names.contains("complete"))
        #expect(!names.contains("gmail__messages_list"))
    }

    @Test("exclude alone keeps the rest")
    func excludeOnly() {
        let names = ToolSelection(exclude: ["mcp:slack:*", "send_email"]).apply(to: catalog, prompt: "").offered.map(\.function.name)
        #expect(!names.contains("slack__post"))
        #expect(!names.contains("send_email"))
        #expect(names.contains("gmail__messages_list"))
    }

    @Test("a lean turn offers the relevant tools and holds the rest back")
    func lean() {
        let selection = ToolSelection(lean: true)
        let applied = selection.apply(to: catalog, prompt: "please search the web for the latest news")
        let offered = applied.offered.map(\.function.name)
        #expect(offered.contains("web_search"))
        #expect(offered.contains("todo") && offered.contains("complete"))
        #expect(applied.deferred.map(\.function.name).contains("send_email"))
        #expect(Set(offered).isDisjoint(with: Set(applied.deferred.map(\.function.name))))
        #expect(offered.count + applied.deferred.count == catalog.count)
    }

    @Test("a lean turn keeps tools the thread already used")
    func leanKeepsUsed() {
        let applied = ToolSelection(lean: true).apply(to: catalog, prompt: "thanks", usedToolNames: ["send_email"])
        #expect(applied.offered.map(\.function.name).contains("send_email"))
    }

    @Test("lean never offers a tool the selectors forbid")
    func leanRespectsExclude() {
        let applied = ToolSelection(exclude: ["web_search"], lean: true).apply(to: catalog, prompt: "search the web")
        let all = (applied.offered + applied.deferred).map(\.function.name)
        #expect(!all.contains("web_search"))
    }

    @Test("held-back tools are announced so the model can ask for them")
    func deferredNote() {
        #expect(ToolSelection.deferredNote([]) == nil)
        let note = ToolSelection.deferredNote([tool("send_email")])
        #expect(note?.contains("send_email") == true)
        #expect(note?.contains("capabilities_load") == true)
    }

    @Test("unknown selectors are reported so typos show")
    func unknown() {
        let selection = ToolSelection(allow: ["read_fil", "mcp:gmail:*", "mcp:nope:*"])
        #expect(selection.unknownSelectors(knownMcpServers: ["gmail"]) == ["read_fil", "mcp:nope:*"])
    }

    @Test("an old bot file decodes without a selection, and a saved selection round-trips")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        let bot = store.createBot(name: "Small", title: "")
        #expect(bot.toolSelection == nil)
        store.setBotToolSelection(bot.id, ToolSelection(allowOnly: true, allow: ["read_file", "bad*"], lean: true))
        let saved = try #require(store.bots.first { $0.id == bot.id }?.toolSelection)
        #expect(saved.allow == ["read_file"])
        #expect(saved.lean)
        let data = try JSONEncoder().encode(store.bots.first { $0.id == bot.id })
        let back = try JSONDecoder().decode(Bot.self, from: data)
        #expect(back.toolSelection == saved)
        store.setBotToolSelection(bot.id, ToolSelection())
        #expect(store.bots.first { $0.id == bot.id }?.toolSelection == nil)
    }

    @Test("a held-back tool joins the request after capabilities_load activates it")
    func loopActivatesDeferredTool() async throws {
        let all = AgentToolCatalog.chatTools(enabledIds: ["read_file", "write_file", "web_search"])
        let applied = ToolSelection(allowOnly: true, allow: ["write_file", "read_file"], lean: true)
            .apply(to: all, prompt: "zzz")
        let held = try #require(applied.deferred.first { $0.function.name == "write_file" })
        #expect(!applied.offered.map(\.function.name).contains("write_file"))

        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "capabilities_load", arguments: "{\"ids\":\"write_file\"}")]),
            ChatCompletionResponse(text: "ok"),
        ])
        var request = AgentLoopRequest(
            endpoint: ModelEndpoint(provider: "openrouter", model: "t", baseURL: "https://example.com/v1", apiKey: "k"),
            botName: "Small",
            prompt: "save a note",
            tools: applied.offered,
            maxSteps: 6
        )
        request.deferredTools = applied.deferred
        _ = try await AgentLoop.run(client: client, request: request) { name, _ in
            name == "capabilities_load"
                ? AgentToolCallResult(output: "builtin write_file is available", activatedToolNames: ["write_file"])
                : AgentToolCallResult(output: "")
        }
        #expect(client.requests.count == 2)
        #expect(!(client.requests[0].tools.map(\.function.name).contains("write_file")))
        #expect(client.requests[1].tools.map(\.function.name).contains(held.function.name))
        let system = client.requests[0].messages.first { $0.role == "system" }?.content ?? ""
        #expect(system.contains("write_file") && system.contains("capabilities_load"))
    }
}
