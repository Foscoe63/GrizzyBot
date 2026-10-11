import Foundation

/// A tool that stops answering must not leave the bot stuck. This races each tool call against a hard
/// time limit and against Stop: if the tool ignores cancellation, Stop still returns after a short
/// grace, and a tool that never returns hands the model a note instead of a frozen turn.
public enum ToolWatchdog {
    /// How long Stop waits for a tool that does not respond to cancellation.
    public static let cancelGrace: TimeInterval = 3

    /// The longest a single call of this tool may run.
    public static func limit(for tool: String) -> TimeInterval {
        switch tool {
        case "run_subagent", "message_bot": return 900
        case "shell", "shell.exec", "shortcuts_run": return 330
        case let t where t.hasPrefix("computer_") || t == "request_takeover": return 120
        case "web_search", "web_fetch": return 120
        default: return 600
        }
    }

    public static func timeoutResult(tool: String, seconds: TimeInterval) -> AgentToolCallResult {
        AgentToolCallResult(
            output: "\(tool) did not respond within \(Int(seconds))s and was abandoned. Do not retry the same call; try another approach or tell the person what is stuck."
        )
    }

    public static func run(
        tool: String,
        limit: TimeInterval? = nil,
        cancelGrace: TimeInterval? = nil,
        work: @escaping @Sendable () async -> AgentToolCallResult
    ) async throws -> AgentToolCallResult {
        let seconds = limit ?? Self.limit(for: tool)
        let grace = cancelGrace ?? Self.cancelGrace
        let gate = Gate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AgentToolCallResult, Error>) in
                gate.install(continuation)
                let worker = Task {
                    let result = await work()
                    gate.finish(.success(result))
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    gate.finish(.success(timeoutResult(tool: tool, seconds: seconds)))
                }
                gate.onFinish = {
                    worker.cancel()
                    timer.cancel()
                }
                gate.onCancelRequested = {
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                        gate.finish(.failure(CancellationError()))
                    }
                }
            }
        } onCancel: {
            gate.requestCancel()
        }
    }

    /// Resumes the continuation exactly once, whichever of work, timer, or Stop gets there first.
    private final class Gate: @unchecked Sendable {
        // Guarded by `lock`.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AgentToolCallResult, Error>?
        private var finished = false
        private var cancelRequested = false
        var onFinish: (@Sendable () -> Void)?
        var onCancelRequested: (@Sendable () -> Void)?

        func install(_ continuation: CheckedContinuation<AgentToolCallResult, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<AgentToolCallResult, Error>) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true
            self.continuation = nil
            let done = onFinish
            lock.unlock()
            continuation.resume(with: result)
            done?()
        }

        func requestCancel() {
            lock.lock()
            guard !cancelRequested else { lock.unlock(); return }
            cancelRequested = true
            let handler = onCancelRequested
            let alreadyDone = finished
            lock.unlock()
            if !alreadyDone { handler?() }
        }
    }
}
