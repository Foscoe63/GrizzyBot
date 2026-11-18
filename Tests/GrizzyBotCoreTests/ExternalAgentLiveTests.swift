import Foundation
import Testing
@testable import GrizzyBotCore

private struct NoModel: ChatCompleting {
    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(text: "")
    }
    func stream(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(text: "")
    }
}

/// Drives `delegate_external` through the real AppStore tool path. The live test needs opencode and
/// a local model, so it only runs when GRIZZY_ACP_LIVE=1.
@Suite("delegate_external")
@MainActor
struct ExternalAgentLiveTests {
    private func world(folder: URL?) -> (store: AppStore, bot: Bot) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "d\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let bot = store.createBot(name: "Ada", title: "Coder", enabledTools: ["delegate_external"])
        if let folder, let i = store.bots.firstIndex(where: { $0.id == bot.id }) {
            store.bots[i].workingFolder = folder.path
        }
        return (store, store.bots.first { $0.id == bot.id }!)
    }

    private let endpoint = ModelEndpoint(provider: "test", model: "none", baseURL: "http://localhost:1", apiKey: "")

    private func run(_ w: (store: AppStore, bot: Bot), _ args: String, approved: Bool) async -> AgentToolCallResult {
        await w.store.executeAgentTool(
            name: "delegate_external", argumentsJSON: args, botId: w.bot.id, depth: 0,
            endpoint: endpoint, client: NoModel(), approved: approved
        )
    }

    @Test("without a working folder it refuses before asking anyone")
    func needsFolder() async {
        let w = world(folder: nil)
        let result = await run(w, #"{"task":"look around"}"#, approved: false)
        #expect(result.output.contains("working folder"))
        #expect(result.pause == nil)
    }

    @Test("with a folder it pauses for approval and names the agent and the access level")
    func asksFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let w = world(folder: folder)
        let result = await run(w, #"{"task":"list the files","access":"edit"}"#, approved: false)
        guard case .approval(let tool, let detail, _)? = result.pause else {
            Issue.record("expected an approval pause, got \(String(describing: result.pause))")
            return
        }
        #expect(tool == "external_agent.run")
        #expect(detail.contains("opencode"))
        #expect(detail.contains("read and edit"))
    }

    @Test("live: approved job reads a file in the working folder through opencode",
          .enabled(if: ProcessInfo.processInfo.environment["GRIZZY_ACP_LIVE"] == "1"))
    func live() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "The secret word is MARMALADE.\n".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        // opencode picks its model from this inline config, so the run is local and free.
        let model = ProcessInfo.processInfo.environment["GRIZZY_ACP_MODEL"] ?? "lmstudio/qwen3-coder-next-mlx@5bit"
        setenv("OPENCODE_CONFIG_CONTENT", #"{"model":"\#(model)"}"#, 1)
        defer { unsetenv("OPENCODE_CONFIG_CONTENT") }
        let w = world(folder: folder)
        let taint = RunTaint()
        let result = await w.store.executeAgentTool(
            name: "delegate_external",
            argumentsJSON: #"{"task":"Read notes.txt in the current folder and tell me the secret word. Do not change anything.","access":"read"}"#,
            botId: w.bot.id, depth: 0, endpoint: endpoint, client: NoModel(), approved: true, taint: taint
        )
        print("DELEGATE OUTPUT:", result.output)
        print("DELEGATE BLOCKS:", result.blocks)
        #expect(result.output.uppercased().contains("MARMALADE"))
        #expect(taint.isTainted)
        let after = try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(after == "The secret word is MARMALADE.\n")
    }
}
