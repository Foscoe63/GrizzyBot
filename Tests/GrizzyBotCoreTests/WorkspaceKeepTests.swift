import Foundation
@testable import GrizzyBotCore
import Testing

@Suite("Workspace is never lost to a save")
struct WorkspaceKeepTests {
    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotKeep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func kept(_ d: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix("workspace.json.kept-") }
    }

    @Test("a file this build cannot read is copied aside before it is replaced")
    func unreadable() throws {
        let d = dir(), p = Persistence(root: d)
        let junk = Data("{ not a workspace".utf8)
        try junk.write(to: d.appendingPathComponent("workspace.json"))
        p.saveWorkspace(UserWorkspace(), userId: "u")
        let copies = kept(d)
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: d.appendingPathComponent(copies[0])) == junk)
    }

    @Test("saving an empty workspace over one with bots keeps the old one")
    func emptyOverBots() throws {
        let d = dir(), p = Persistence(root: d)
        var ws = UserWorkspace()
        ws.bots = [Bot(id: "b", name: "Ada", color: "#888888", threadId: "t")]
        p.saveWorkspace(ws, userId: "u")
        #expect(kept(d).isEmpty)
        p.saveWorkspace(UserWorkspace(), userId: "u")
        #expect(kept(d).count == 1)
        let back = try p.decodeJSON(UserWorkspace.self, from: Data(contentsOf: d.appendingPathComponent(kept(d)[0])))
        #expect(back.bots.count == 1)
    }

    @Test("ordinary saves leave no copies")
    func ordinary() {
        let d = dir(), p = Persistence(root: d)
        var ws = UserWorkspace()
        ws.bots = [Bot(id: "b", name: "Ada", color: "#888888", threadId: "t")]
        p.saveWorkspace(ws, userId: "u")
        ws.bots[0].name = "Bo"
        p.saveWorkspace(ws, userId: "u")
        #expect(kept(d).isEmpty)
    }
}
