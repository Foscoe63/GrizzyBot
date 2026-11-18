import Foundation

/// Tracks whether a run is still moving, so a stuck run is stopped in minutes instead of waiting out the
/// overall cap, and so a stopped run can say what it already finished.
final class RunProgress: @unchecked Sendable {
    /// How long the model may go without any sign of life (a step, a streamed token, a tool result).
    let modelIdleLimit: TimeInterval
    /// Extra time a running tool gets beyond its own `ToolWatchdog` limit.
    let toolSlack: TimeInterval

    // Guarded by `lock`.
    private let lock = NSLock()
    private var lastActivity = Date()
    private var inFlight: [String: Int] = [:]
    private var completed: [String] = []

    init(modelIdleLimit: TimeInterval = 360, toolSlack: TimeInterval = 60) {
        self.modelIdleLimit = modelIdleLimit
        self.toolSlack = toolSlack
    }

    func touch() {
        lock.lock(); lastActivity = Date(); lock.unlock()
    }

    func toolStarted(_ name: String) {
        lock.lock()
        inFlight[name, default: 0] += 1
        lastActivity = Date()
        lock.unlock()
    }

    func toolFinished(_ name: String, output: String) {
        lock.lock()
        if let n = inFlight[name], n > 1 { inFlight[name] = n - 1 } else { inFlight.removeValue(forKey: name) }
        lastActivity = Date()
        let line = output.split(separator: "\n").first.map { String($0.prefix(140)) } ?? ""
        completed.append(line.isEmpty ? name : "\(name): \(line)")
        lock.unlock()
    }

    /// The tool the run is waiting on, if any, with the longest limit among those running.
    private func waitingTool() -> (name: String, limit: TimeInterval)? {
        inFlight.keys
            .map { ($0, ToolWatchdog.limit(for: $0)) }
            .max { $0.1 < $1.1 }
            .map { (name: $0.0, limit: $0.1) }
    }

    /// Non-nil when the run has been silent longer than whatever it is waiting on should take.
    func stall(now: Date = Date()) -> RunStalledError? {
        lock.lock(); defer { lock.unlock() }
        let idle = now.timeIntervalSince(lastActivity)
        if let tool = waitingTool() {
            return idle > tool.limit + toolSlack ? RunStalledError(idleSeconds: Int(idle), tool: tool.name) : nil
        }
        return idle > modelIdleLimit ? RunStalledError(idleSeconds: Int(idle), tool: nil) : nil
    }

    /// Bullet list of the tool steps that finished, newest last, or "" when none did.
    func completedSummary(limit: Int = 8) -> String {
        lock.lock(); defer { lock.unlock() }
        guard !completed.isEmpty else { return "" }
        let shown = completed.suffix(limit).map { "- \($0)" }.joined(separator: "\n")
        let hidden = completed.count - min(limit, completed.count)
        return (hidden > 0 ? "- …\(hidden) earlier step(s)\n" : "") + shown
    }
}

struct RunStalledError: LocalizedError {
    let idleSeconds: Int
    let tool: String?
    var errorDescription: String? {
        if let tool {
            return "\(tool) made no progress for \(max(1, idleSeconds / 60)) minutes, so the run was stopped."
        }
        return "The model went quiet for \(max(1, idleSeconds / 60)) minutes, so the run was stopped."
    }
}

extension AppStore {
    /// Stops a run that has stalled (no progress for longer than its current step should take) or that has
    /// outlived `seconds` in total, whichever comes first.
    static func withRunWatchdog<T: Sendable>(
        seconds: Int,
        progress: RunProgress,
        pollSeconds: Double = 5,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                let started = Date()
                while true {
                    try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                    if let stalled = progress.stall() { throw stalled }
                    if Date().timeIntervalSince(started) >= Double(seconds) { throw RunDeadlineError(seconds: seconds) }
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// The message shown when a run is stopped, with whatever it finished first.
    static func stoppedRunMessage(_ error: Error, progress: RunProgress) -> String {
        var text = "I couldn't finish that: \(error.localizedDescription)"
        let done = progress.completedSummary()
        if !done.isEmpty {
            text += "\n\nThese steps finished before it stopped, so that work is likely done:\n\(done)"
        }
        return text
    }
}
