import Foundation
import GrizzyBotCore
import Testing

@Suite("Shell runner")
struct ShellRunnerTests {
    private func makeHome() -> (BotHomeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-shell-\(UUID().uuidString)", isDirectory: true)
        return (BotHomeStore(root: root), root)
    }

    @Test("output far past the 64 KB pipe buffer returns instead of hanging")
    func largeOutput() async throws {
        let (home, root) = makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await home.runShell(
            botId: "b", command: "head -c 600000 /dev/zero | tr '\\0' 'x'; echo done >&2", timeout: 20
        )
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 20_000)
        #expect(result.stderr.contains("done"))
    }

    @Test("exit codes and stderr come back")
    func exitCode() async throws {
        let (home, root) = makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await home.runShell(botId: "b", command: "echo oops >&2; exit 7", timeout: 20)
        #expect(result.exitCode == 7)
        #expect(result.stderr.contains("oops"))
    }

    @Test("a timeout kills the command's children too")
    func timeoutKillsGroup() async throws {
        let (home, root) = makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "grizzy-orphan-\(UUID().uuidString.prefix(8))"
        let started = Date()
        let result = try await home.runShell(
            botId: "b", command: "(sleep 300; echo \(marker)) & wait", timeout: 1
        )
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        try await Task.sleep(for: .milliseconds(300))
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(!listing.contains(marker))
    }

    @Test("cancelling the task stops a running command")
    func cancelStops() async throws {
        let (home, root) = makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let task = Task {
            try await home.runShell(botId: "b", command: "sleep 300", timeout: 600)
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a cancellation")
        } catch is CancellationError {
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a backgrounded child holding the pipes does not wedge the command")
    func backgroundChild() async throws {
        let (home, root) = makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let result = try await home.runShell(botId: "b", command: "echo hi; (sleep 5 &) ; exit 0", timeout: 20)
        #expect(result.stdout.contains("hi"))
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test("shell history and tool credentials are unreadable")
    func deniedReads() {
        let profile = BotHomeStore.seatbeltProfile(home: URL(fileURLWithPath: "/tmp/h"))
        for path in [".config/gh", ".npmrc", ".netrc", ".zsh_history", "Library/Mail", "Library/Messages"] {
            #expect(profile.contains("(deny file-read* (subpath \"\(FileManager.default.homeDirectoryForCurrentUser.path)/\(path)\"))"))
        }
    }
}
