import Foundation
import GrizzyBotCore
import Testing

/// A stdio MCP server that accepts requests and never answers is the case the request
/// timeout exists for. These tests pin that the client gives up on its own.
@Suite("McpClient timeouts")
struct McpTimeoutTests {

    /// `sleep` reads nothing and writes nothing: stdin stays open, stdout never produces a
    /// JSON-RPC reply, so every request rides the timeout path.
    private func unresponsiveServer() -> McpServer {
        McpServer(
            id: "unresponsive",
            name: "unresponsive",
            command: "/bin/sleep",
            args: ["300"]
        )
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Runs `work`, reporting whether it finished at all inside `within`.
    ///
    /// Deliberately does not await `work`: a task group waits for its children, so racing a
    /// hung call inside one makes the *test* hang too — the very bug under test. The work runs
    /// detached and we poll a flag, so a hang fails in `seconds` instead of never.
    private func completes(
        within seconds: Double,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let done = Flag()
        Task.detached {
            await work()
            done.raise()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done.isRaised { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return done.isRaised
    }

    @Test("listTools gives up on a server that never answers")
    func listToolsTimesOut() async {
        let finished = await completes(within: 12) {
            _ = try? await McpClient.listTools(server: unresponsiveServer(), timeout: 2)
        }
        #expect(finished, "listTools hung past its 2s timeout")
    }

    @Test("call gives up on a server that never answers")
    func callTimesOut() async {
        let finished = await completes(within: 12) {
            _ = try? await McpClient.call(
                server: unresponsiveServer(),
                toolName: "anything",
                timeout: 2
            )
        }
        #expect(finished, "call hung past its 2s timeout")
    }
}
