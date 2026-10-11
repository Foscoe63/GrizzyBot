import Foundation
import GrizzyBotCore
import Testing

@Suite("Checkpoints")
struct CheckpointTests {
    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a changed file is restored, a created file is removed")
    func restoreAndRemove() throws {
        let home = temp()
        let existing = home.appendingPathComponent("a.txt")
        let created = home.appendingPathComponent("b.txt")
        try "original".write(to: existing, atomically: true, encoding: .utf8)

        CheckpointStore.record(home: home, runId: "r1", label: "write_file", paths: [existing.path, created.path])
        try "changed".write(to: existing, atomically: true, encoding: .utf8)
        try "new".write(to: created, atomically: true, encoding: .utf8)

        let result = CheckpointStore.rollback(home: home)
        #expect(result?.restored.count == 2)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(CheckpointStore.list(home: home).isEmpty)
        #expect(CheckpointStore.rollback(home: home) == nil)
    }

    @Test("one run, several edits: rollback returns to before the run")
    func earliestStateWins() throws {
        let home = temp()
        let file = home.appendingPathComponent("doc.md")
        try "v0".write(to: file, atomically: true, encoding: .utf8)
        CheckpointStore.record(home: home, runId: "run", label: "edit_file", paths: [file.path])
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        CheckpointStore.record(home: home, runId: "run", label: "edit_file", paths: [file.path])
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        #expect(CheckpointStore.list(home: home).count == 1)
        CheckpointStore.rollback(home: home)
        #expect(try String(contentsOf: file, encoding: .utf8) == "v0")
    }

    @Test("a deleted file and a moved file come back")
    func deleteAndMove() throws {
        let home = temp()
        let a = home.appendingPathComponent("a.txt")
        let b = home.appendingPathComponent("b.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        CheckpointStore.record(home: home, runId: "r", label: "move_file", paths: [a.path, b.path])
        try FileManager.default.moveItem(at: a, to: b)
        CheckpointStore.rollback(home: home)
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test("separate runs make separate checkpoints and a specific one can be chosen")
    func choose() throws {
        let home = temp()
        let file = home.appendingPathComponent("f.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let first = CheckpointStore.record(home: home, runId: "r1", label: "x", paths: [file.path], now: Date().addingTimeInterval(-60))
        try "two".write(to: file, atomically: true, encoding: .utf8)
        CheckpointStore.record(home: home, runId: "r2", label: "x", paths: [file.path])
        try "three".write(to: file, atomically: true, encoding: .utf8)
        #expect(CheckpointStore.list(home: home).count == 2)
        CheckpointStore.rollback(home: home, id: String(first!.id.prefix(10)))
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        #expect(CheckpointStore.rollback(home: home, id: "nope") == nil)
    }

    @Test("only the most recent checkpoints are kept")
    func pruning() throws {
        let home = temp()
        let file = home.appendingPathComponent("p.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        for i in 0..<(CheckpointStore.maxKept + 5) {
            CheckpointStore.record(home: home, runId: "run\(i)", label: "x", paths: [file.path], now: Date().addingTimeInterval(Double(i)))
        }
        #expect(CheckpointStore.list(home: home).count == CheckpointStore.maxKept)
    }
}

@Suite("Rollback command")
@MainActor
struct RollbackCommandTests {
    @Test("with nothing recorded it says so")
    func empty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        let bot = store.createBot(name: "Ada", title: "")
        store.send(botId: bot.id, text: "/rollback")
        let reply = store.threads[bot.id]?.messages.last(where: { $0.role == .bot })?.firstText ?? ""
        #expect(reply.contains("Nothing to roll back"))
        store.send(botId: bot.id, text: "/rollback list")
        #expect((store.threads[bot.id]?.messages.last(where: { $0.role == .bot })?.firstText ?? "").contains("No checkpoints"))
    }
}
