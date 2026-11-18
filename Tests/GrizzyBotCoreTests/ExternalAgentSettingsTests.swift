import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("External agent settings")
@MainActor
struct ExternalAgentSettingsTests {
    @Test("command lines split into words, honouring quotes")
    func parsing() {
        #expect(ExternalAgentSpec.parseCommandLine("opencode acp") == ["opencode", "acp"])
        #expect(ExternalAgentSpec.parseCommandLine("  npx   -y  pkg ") == ["npx", "-y", "pkg"])
        #expect(ExternalAgentSpec.parseCommandLine(#"agent --dir "My Projects/x" 'a b'"#) == ["agent", "--dir", "My Projects/x", "a b"])
        #expect(ExternalAgentSpec.parseCommandLine(#"say \"hi\""#) == ["say", "\"hi\""])
        #expect(ExternalAgentSpec.parseCommandLine("") == [])
        #expect(ExternalAgentSpec.parseCommandLine(#"a "" b"#) == ["a", "", "b"])
    }

    @Test("problems are named, ids are unique and never shadow a built-in")
    func validation() {
        #expect(ExternalAgentSpec.commandProblem([]) != nil)
        #expect(ExternalAgentSpec.commandProblem(["KEY=1", "agent"]) != nil)
        #expect(ExternalAgentSpec.commandProblem(["/usr/local/bin/agent", "acp"]) == nil)
        #expect(ExternalAgentSpec.makeId(from: "My Agent!", existing: []) == "my-agent")
        #expect(ExternalAgentSpec.makeId(from: "opencode", existing: []) == "opencode-2")
        let first = ExternalAgentSpec(id: "my-agent", name: "My Agent", command: ["x"])
        #expect(ExternalAgentSpec.makeId(from: "My Agent", existing: [first]) == "my-agent-2")
        #expect(ExternalAgentSpec.makeId(from: "???", existing: []) == "agent")
    }

    @Test("lookup finds built-in and custom agents by id or name, and empty means the first built-in")
    func lookup() {
        let mine = ExternalAgentSpec(id: "mine", name: "My Agent", command: ["x"])
        #expect(ExternalAgentSpec.named("")?.id == "opencode")
        #expect(ExternalAgentSpec.named("OpenCode")?.id == "opencode")
        #expect(ExternalAgentSpec.named("my agent", custom: [mine])?.id == "mine")
        #expect(ExternalAgentSpec.named("mine")?.id == nil)
        #expect(ExternalAgentSpec.isPreset("opencode"))
        #expect(!ExternalAgentSpec.isPreset("mine"))
    }

    @Test("the store adds, rejects duplicates and bad commands, and removes, but never removes a built-in")
    func storeCrud() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "d\(UUID().uuidString.prefix(6))@b.com", password: "password1")

        #expect(store.addExternalAgent(name: "", commandLine: "x acp") != nil)
        #expect(store.addExternalAgent(name: "Mine", commandLine: "  ") != nil)
        #expect(store.addExternalAgent(name: "Mine", commandLine: "mine-agent --acp") == nil)
        #expect(store.externalAgents.map(\.id) == ["mine"])
        #expect(store.externalAgents.first?.command == ["mine-agent", "--acp"])
        #expect(store.addExternalAgent(name: "mine", commandLine: "other") != nil)
        #expect(store.addExternalAgent(name: "OpenCode", commandLine: "other") != nil)
        store.deleteExternalAgent("opencode")
        #expect(ExternalAgentSpec.named("opencode") != nil)
        store.deleteExternalAgent("mine")
        #expect(store.externalAgents.isEmpty)
    }

    @Test("custom agents survive a save and load, and old workspaces without the field still open")
    func persistence() throws {
        var workspace = UserWorkspace()
        workspace.externalAgents = [ExternalAgentSpec(id: "mine", name: "Mine", command: ["a", "b c"])]
        let data = try JSONEncoder().encode(workspace)
        #expect(try JSONDecoder().decode(UserWorkspace.self, from: data).externalAgents == workspace.externalAgents)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["externalAgents"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(UserWorkspace.self, from: old).externalAgents.isEmpty)
    }

    @Test("the tool lists custom agents so a bot knows their names")
    func toolNamesCustomAgents() {
        let mine = ExternalAgentSpec(id: "mine", name: "Mine", command: ["x"])
        let tools = AgentToolCatalog.chatTools(enabledIds: ["delegate_external"], externalAgents: [mine])
        let description = tools.first { $0.function.name == "delegate_external" }?.function.description ?? ""
        #expect(description.contains("opencode"))
        #expect(description.contains("mine"))
    }

    @Test("Test reports a missing program as a failure, without hanging")
    func testMissing() async {
        let spec = ExternalAgentSpec(id: "nope", name: "Nope", command: ["definitely-not-a-real-acp-agent"])
        let result = await AppStore.testExternalAgent(spec)
        #expect(!result.ok)
        #expect(!result.text.isEmpty)
        #expect(await AppStore.testExternalAgent(ExternalAgentSpec(id: "e", name: "E", command: [])).ok == false)
    }

    @Test("Test succeeds against an agent that answers the handshake")
    func testWorking() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).py")
        try """
        import sys, json
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("method") == "initialize":
                print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentInfo": {"name": "Fake"}}}), flush=True)
            elif m.get("method") == "session/new":
                print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s"}}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let result = await AppStore.testExternalAgent(ExternalAgentSpec(id: "f", name: "F", command: ["python3", script.path]))
        #expect(result.ok)
        #expect(result.text == "Fake is ready")
    }

    @Test("the tool starts off for new bots and new installs, and a relaunch never switches it on")
    func optInOnly() throws {
        #expect(AgentToolCatalog.builtinIds.contains("delegate_external"))
        #expect(!AgentToolCatalog.allIds.contains("delegate_external"))
        #expect(!AppConfig().defaultEnabledTools.contains("delegate_external"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = AppStore(dataDirectory: dir, delayScale: 0.01)
        let bot = first.createBot(name: "Ada", title: "Coder")
        #expect(!bot.enabledTools.contains("delegate_external"))
        first.save()

        let second = AppStore(dataDirectory: dir, delayScale: 0.01)
        #expect(second.bots.contains { $0.id == bot.id })
        #expect(second.bots.allSatisfy { !$0.enabledTools.contains("delegate_external") })
        #expect(!second.appConfig.defaultEnabledTools.contains("delegate_external"))
        #expect(second.appConfig.seenToolIds.contains("delegate_external"))

        // Switching it on deliberately still works.
        second.setAllDefaultTools(enabled: true)
        #expect(second.appConfig.defaultEnabledTools.contains("delegate_external"))
    }

    @Test("LM Studio's model list keeps only loaded llm/vlm models")
    func lmStudioParsing() {
        let json = #"{"data":[{"id":"a","state":"loaded","type":"llm","loaded_context_length":8192,"max_context_length":32768},{"id":"b","state":"not-loaded","type":"llm"},{"id":"e","state":"loaded","type":"embeddings"},{"id":"v","state":"loaded","type":"vlm","max_context_length":4096}]}"#
        let m = LMStudioModels.parse(Data(json.utf8))
        #expect(m.map(\.id) == ["a", "v"])
        #expect(m.map(\.contextLength) == [8192, 4096])
        #expect(LMStudioModels.openCodeValue(m[0]) == "lmstudio/a")
        #expect(LMStudioModels.parse(Data("nope".utf8)).isEmpty)
    }
}
