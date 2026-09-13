import Foundation

public enum ShortcutsError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case emptyName
    case failed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Shortcuts command line tool is not available on this Mac."
        case .emptyName:
            return "name is required"
        case .failed(let message):
            return message.isEmpty ? "The shortcut failed." : message
        case .timedOut(let seconds):
            return "The shortcut did not finish within \(Int(seconds))s and was stopped."
        }
    }
}

/// Runs Shortcuts through `/usr/bin/shortcuts`.
///
/// Structured system automation, as against driving the UI: a shortcut named
/// "Toggle Do Not Disturb" does the thing, where the computer tools would have
/// to find and click a menu that moves between OS versions.
///
/// Arguments go to the process as an array — never a shell string — so a
/// shortcut name is data and cannot become a command.
public enum ShortcutsRuntime {
    public static let binaryPath = "/usr/bin/shortcuts"

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    struct Execution: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Every shortcut in the user's library, one per line from the CLI.
    public static func list(timeout: TimeInterval = 20) async throws -> [String] {
        guard isAvailable else { throw ShortcutsError.unavailable }
        let run = try await execute(["list"], timeout: timeout)
        guard run.status == 0 else { throw ShortcutsError.failed(message(from: run)) }
        return run.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Runs one shortcut and returns whatever it produced as text.
    ///
    /// `shortcuts run` discards the result unless it is given somewhere to put
    /// it, so output goes to a temporary file and is read back. A shortcut that
    /// returns nothing is not an error — plenty of them only have an effect.
    public static func run(
        name: String,
        input: String? = nil,
        timeout: TimeInterval = 120
    ) async throws -> String {
        guard isAvailable else { throw ShortcutsError.unavailable }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShortcutsError.emptyName }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzybot-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var arguments = ["run", trimmed]
        if let input, !input.isEmpty {
            let inputURL = scratch.appendingPathComponent("input.txt")
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputURL.path]
        }
        let outputURL = scratch.appendingPathComponent("output.txt")
        arguments += ["--output-path", outputURL.path, "--output-type", "public.plain-text"]

        let run = try await execute(arguments, timeout: timeout)
        // The CLI reports a missing or failing shortcut on stderr with a
        // non-zero status; stdout stays empty, so the status is what to trust.
        guard run.status == 0 else { throw ShortcutsError.failed(message(from: run)) }

        let produced = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let combined = produced.isEmpty ? run.stdout : produced
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(from run: Execution) -> String {
        let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "shortcuts exited with status \(run.status)."
    }

    /// Off the calling actor: Process work blocks, and prompt handling runs on
    /// the main actor.
    static func execute(_ arguments: [String], timeout: TimeInterval) async throws -> Execution {
        try await Task.detached(priority: .userInitiated) {
            try executeBlocking(arguments, timeout: timeout)
        }.value
    }

    /// Synchronous on purpose: draining two pipes without deadlocking needs
    /// DispatchGroup.wait, which is unavailable from an async context. The
    /// detached task above is what keeps it off the caller's actor.
    private static func executeBlocking(_ arguments: [String], timeout: TimeInterval) throws -> Execution {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            // Both pipes are drained on their own threads. Reading one to the
            // end before the other deadlocks as soon as the un-drained pipe
            // fills its buffer.
            let group = DispatchGroup()
            let box = OutputBox()
            for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    box.set(String(data: data, encoding: .utf8) ?? "", isStdout: isStdout)
                    group.leave()
                }
            }

            let deadline = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

            process.waitUntilExit()
            let timedOut = deadline.isCancelled == false && process.terminationReason == .uncaughtSignal
            deadline.cancel()
            group.wait()

            if timedOut { throw ShortcutsError.timedOut(timeout) }
            return Execution(status: process.terminationStatus, stdout: box.stdout, stderr: box.stderr)
    }
}

/// Two background readers write here; a lock is cheaper than threading a queue
/// through for two small strings.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func set(_ value: String, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { out = value } else { err = value }
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return err
    }
}
