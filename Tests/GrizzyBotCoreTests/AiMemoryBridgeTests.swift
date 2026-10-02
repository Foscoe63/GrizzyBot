import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct AiMemoryBridgeTests {
    private func bridge() -> AiMemoryBridge {
        AiMemoryBridge(
            config: .init(
                server: URL(string: "http://127.0.0.1:49374")!,
                workspace: "grizzybot", project: "scout", cwd: "/tmp/home"
            ),
            sessionId: "s1"
        )
    }

    @Test func projectSlugIsStableAndSafe() {
        #expect(AiMemoryBridge.projectSlug("Scout Bot!") == "scout-bot")
        #expect(AiMemoryBridge.projectSlug("   ") == "grizzybot")
    }

    @Test func hookURLCarriesEventAndScope() throws {
        let url = try #require(bridge().hookURL(for: .postToolUse))
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/hook")
        #expect(items["event"] == "post-tool-use")
        #expect(items["agent"] == "grizzybot")
        #expect(items["workspace"] == "grizzybot")
        #expect(items["project"] == "scout")
    }

    @Test func payloadHasHookShape() {
        let body = bridge().payload(.userPromptSubmit, fields: ["prompt": "hi"])
        #expect(body["session_id"] as? String == "s1")
        #expect(body["hook_event_name"] as? String == "UserPromptSubmit")
        #expect(body["prompt"] as? String == "hi")
    }

    @Test func disabledByEnvironment() {
        #expect(AiMemoryBridge.make(botName: "x", cwd: "/", environment: ["GRIZZYBOT_AI_MEMORY": "0"]) == nil)
        #expect(AiMemoryBridge.make(botName: "x", cwd: "/", environment: [:]) != nil)
    }

    @Test func clipsLongResponses() {
        let clipped = AiMemoryBridge.clip(String(repeating: "a", count: 10_000))
        #expect(clipped.count <= AiMemoryBridge.responseLimit + 1)
    }

    @Test func unreachableServerNeverThrowsOrBlocks() async {
        let dead = AiMemoryBridge(config: .init(
            server: URL(string: "http://127.0.0.1:1")!, workspace: "w", project: "p", cwd: "/"
        ))
        dead.emit(.sessionStart)
        await dead.flush()
        #expect(await dead.pendingHandoff() == nil)
    }

    @Test func probeReportsDisabled() async {
        let probe = await AiMemoryBridge.probe(environment: ["GRIZZYBOT_AI_MEMORY": "off"])
        #expect(probe.enabled == false)
    }

    @Test func probeReportsUnreachableServerAndTokenSource() async {
        let probe = await AiMemoryBridge.probe(environment: [
            "AI_MEMORY_HOOK_URL": "http://127.0.0.1:1",
            "AI_MEMORY_AUTH_TOKEN": "t",
        ])
        #expect(probe.enabled)
        #expect(probe.tokenSource == .environment)
        guard case .backingOff(_, let reason) = probe.health else {
            Issue.record("expected backingOff, got \(probe.health)")
            return
        }
        #expect(reason == "server unreachable")
    }
}
