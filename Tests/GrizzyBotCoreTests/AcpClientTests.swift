import Foundation
import GrizzyBotCore
import Testing

/// A tiny stand-in ACP agent: answers the handshake, streams a message, asks permission once, finishes.
private let fakeAgent = #"""
import sys, json
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line)
    method, i = m.get("method"), m.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": 1, "agentInfo": {"name": "Fake"}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": i, "result": {"sessionId": "s1"}})
    elif method == "session/prompt":
        sid = m["params"]["sessionId"]
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello "}}}})
        send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {
            "sessionId": sid, "toolCall": {"toolCallId": "t1", "title": "rm -rf build", "kind": "execute"},
            "options": [{"optionId": "once", "name": "Allow once", "kind": "allow_once"},
                        {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
        reply = json.loads(sys.stdin.readline())
        outcome = reply["result"]["outcome"]
        word = outcome.get("optionId", "cancelled")
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "world: " + word}}}})
        send({"jsonrpc": "2.0", "id": i, "result": {"stopReason": "end_turn"}})
"""#

@Suite("External agent policy")
struct ExternalAgentPolicyTests {
    private func request(_ kind: String) -> AcpPermissionRequest {
        AcpPermissionRequest(toolTitle: "t", toolKind: kind, options: [
            .init(id: "once", name: "Allow once", kind: "allow_once"),
            .init(id: "always", name: "Always", kind: "allow_always"),
            .init(id: "no", name: "Reject", kind: "reject_once"),
        ])
    }

    @Test("read access allows looking and refuses everything else")
    func readAccess() {
        for kind in ["read", "search", "think", "fetch"] {
            #expect(AcpPermissionPolicy.choose(request(kind), access: .read) == "once")
        }
        for kind in ["edit", "execute", "delete", "move", "other", ""] {
            #expect(AcpPermissionPolicy.choose(request(kind), access: .read) == "no")
        }
    }

    @Test("edit access adds edits, but never commands, deletes or moves")
    func editAccess() {
        #expect(AcpPermissionPolicy.choose(request("edit"), access: .edit) == "once")
        for kind in ["execute", "delete", "move", "switch_mode", "other"] {
            #expect(AcpPermissionPolicy.choose(request(kind), access: .edit) == "no")
        }
    }

    @Test("never picks allow_always, and cancels when there is no reject option")
    func neverAlways() {
        let onlyAlways = AcpPermissionRequest(toolTitle: "t", toolKind: "read", options: [
            .init(id: "always", name: "Always", kind: "allow_always"),
        ])
        #expect(AcpPermissionPolicy.choose(onlyAlways, access: .read) == nil)
    }

    @Test("access parses to read unless it says edit")
    func parse() {
        #expect(ExternalAgentAccess.parse("EDIT") == .edit)
        #expect(ExternalAgentAccess.parse("") == .read)
        #expect(ExternalAgentAccess.parse("write everything") == .read)
    }

    @Test("the tool is in the catalog, off unless a bot enables it")
    func catalog() {
        #expect(AgentToolCatalog.builtin.contains { $0.id == "delegate_external" })
        let off = AgentToolCatalog.chatTools(enabledIds: ["read_file"], mcpServers: [])
        #expect(!off.contains { $0.function.name == "delegate_external" })
        let on = AgentToolCatalog.chatTools(enabledIds: ["delegate_external"], mcpServers: [])
        #expect(on.contains { $0.function.name == "delegate_external" })
        #expect(ToolWatchdog.limit(for: "delegate_external") == 1800)
    }
}

@Suite("ACP client")
struct AcpClientTests {
    private func fakeAgentURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-acp-\(UUID().uuidString).py")
        try fakeAgent.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("handshake, streamed text and an approved permission")
    func approved() async throws {
        let script = try fakeAgentURL()
        defer { try? FileManager.default.removeItem(at: script) }
        let client = try AcpClient(command: ["python3", script.path], cwd: NSTemporaryDirectory())
        let id = try await client.start(cwd: NSTemporaryDirectory())
        #expect(id == "s1")
        #expect(await client.agentName == "Fake")
        let result = try await client.prompt("go", onPermission: { ask in
            #expect(ask.toolTitle == "rm -rf build")
            return ask.options.first { $0.kind == "allow_once" }?.id
        })
        #expect(result.text == "Hello world: once")
        #expect(result.stopReason == "end_turn")
        await client.close()
    }

    @Test("no permission handler means the agent is told no")
    func unattended() async throws {
        let script = try fakeAgentURL()
        defer { try? FileManager.default.removeItem(at: script) }
        let client = try AcpClient(command: ["python3", script.path], cwd: NSTemporaryDirectory())
        try await client.start(cwd: NSTemporaryDirectory())
        let result = try await client.prompt("go")
        #expect(result.text == "Hello world: cancelled")
        await client.close()
    }

    @Test("a missing program fails to launch or exits with an error, never hangs")
    func missingProgram() async throws {
        let client = try AcpClient(command: ["definitely-not-a-real-acp-agent"], cwd: NSTemporaryDirectory())
        await #expect(throws: (any Error).self) { try await client.start(cwd: NSTemporaryDirectory()) }
        await client.close()
    }

    /// Real agent, real model call: only runs when GRIZZY_ACP_LIVE=1.
    @Test("live: opencode acp answers a trivial prompt", .enabled(if: ProcessInfo.processInfo.environment["GRIZZY_ACP_LIVE"] == "1"))
    func live() async throws {
        let dir = NSTemporaryDirectory()
        let client = try AcpClient(command: ["opencode", "acp"], cwd: dir)
        try await client.start(cwd: dir)
        // A local model, so the check costs nothing and does not depend on a hosted key.
        let model = ProcessInfo.processInfo.environment["GRIZZY_ACP_MODEL"] ?? "lmstudio/qwen3-4b-instruct-2507-mlx"
        try await client.setConfigOption("model", value: model)
        let result = try await client.prompt(
            "Reply with exactly the word PONG and do not use any tools.",
            onUpdate: { print("ACP update:", $0) },
            onPermission: { _ in nil }
        )
        print("ACP live result:", result)
        #expect(result.stopReason == "end_turn")
        #expect(!result.text.isEmpty)
        await client.close()
    }
}
