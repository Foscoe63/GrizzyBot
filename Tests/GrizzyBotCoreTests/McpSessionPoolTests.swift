import Foundation
import GrizzyBotCore
import Testing

/// Pooling is only worth anything if repeated calls actually reuse one process, so these tests
/// count spawns rather than trusting the pool's bookkeeping.
@Suite("McpSessionPool", .serialized)
struct McpSessionPoolTests {

    /// A minimal stdio MCP server that appends a line to `SPAWN_LOG` each time it starts.
    ///
    /// Written out by the test rather than read from the environment: a fixture that can go
    /// missing turns these into tests that pass without asserting anything.
    private static let serverSource = """
    import json, sys, os
    with open(os.environ["SPAWN_LOG"], "a") as f:
        f.write("start\\n")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if "id" not in msg:
            continue
        m = msg.get("method")
        if m == "initialize":
            r = {"protocolVersion": "2025-11-25", "capabilities": {}, "serverInfo": {"name": "fake", "version": "1"}}
        elif m == "tools/list":
            r = {"tools": [{"name": "echo", "description": "echo", "inputSchema": {"type": "object"}}]}
        elif m == "tools/call":
            r = {"content": [{"type": "text", "text": "ok"}], "isError": False}
        else:
            r = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": r}) + "\\n")
        sys.stdout.flush()
    """

    private func writeServerScript() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mcp-\(UUID().uuidString).py")
        try Self.serverSource.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func countingServer(id: String, script: URL, log: URL) -> McpServer {
        McpServer(
            id: id,
            name: id,
            transport: .stdio,
            command: "/usr/bin/python3",
            args: [script.path],
            env: ["SPAWN_LOG": log.path]
        )
    }

    private func spawnCount(_ log: URL) -> Int {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(separator: "\n").filter { $0 == "start" }.count ?? 0
    }

    private func tempLog() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-spawns-\(UUID().uuidString).log")
    }

    @Test("repeated calls reuse one server process")
    func reusesOneProcess() async throws {
        let log = tempLog()
        let script = try writeServerScript()
        let server = countingServer(id: "pool-reuse", script: script, log: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: script)
        }
        await McpSessionPool.shared.shutdown()

        for _ in 0..<5 {
            let result = try await McpClient.call(server: server, toolName: "echo", timeout: 10)
            #expect(result.text == "ok")
        }

        #expect(spawnCount(log) == 1, "expected one process for five calls, got \(spawnCount(log))")
        await McpSessionPool.shared.shutdown()
    }

    @Test("listTools and call share a session")
    func listAndCallShare() async throws {
        let log = tempLog()
        let script = try writeServerScript()
        let server = countingServer(id: "pool-share", script: script, log: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: script)
        }
        await McpSessionPool.shared.shutdown()

        _ = try await McpClient.listTools(server: server, timeout: 10)
        _ = try await McpClient.call(server: server, toolName: "echo", timeout: 10)

        #expect(spawnCount(log) == 1, "listTools and call should share one process")
        await McpSessionPool.shared.shutdown()
    }

    @Test("concurrent callers do not each spawn a process")
    func concurrentCallersShareOneSpawn() async throws {
        let log = tempLog()
        let script = try writeServerScript()
        let server = countingServer(id: "pool-concurrent", script: script, log: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: script)
        }
        await McpSessionPool.shared.shutdown()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? await McpClient.call(server: server, toolName: "echo", timeout: 10)
                }
            }
        }

        #expect(spawnCount(log) == 1, "six concurrent calls spawned \(spawnCount(log)) processes")
        await McpSessionPool.shared.shutdown()
    }

    @Test("shutdown closes sessions so the next call reopens")
    func shutdownForcesReopen() async throws {
        let log = tempLog()
        let script = try writeServerScript()
        let server = countingServer(id: "pool-shutdown", script: script, log: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: script)
        }
        await McpSessionPool.shared.shutdown()

        _ = try await McpClient.call(server: server, toolName: "echo", timeout: 10)
        await McpSessionPool.shared.shutdown()
        _ = try await McpClient.call(server: server, toolName: "echo", timeout: 10)

        #expect(spawnCount(log) == 2, "shutdown should force a fresh process")
        await McpSessionPool.shared.shutdown()
    }

    /// Editing a server's command must not keep serving the old process.
    @Test("a changed configuration is not reused")
    func changedConfigOpensNewSession() async throws {
        let log = tempLog()
        let script = try writeServerScript()
        var server = countingServer(id: "pool-config", script: script, log: log)
        defer {
            try? FileManager.default.removeItem(at: log)
            try? FileManager.default.removeItem(at: script)
        }
        await McpSessionPool.shared.shutdown()

        _ = try await McpClient.call(server: server, toolName: "echo", timeout: 10)
        server.env["EXTRA"] = "changed"
        _ = try await McpClient.call(server: server, toolName: "echo", timeout: 10)

        #expect(spawnCount(log) == 2, "an edited config should open its own process")
        await McpSessionPool.shared.shutdown()
    }
}
