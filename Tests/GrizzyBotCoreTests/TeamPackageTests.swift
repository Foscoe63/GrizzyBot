import Foundation
import GrizzyBotCore
import Testing

@Suite("Team packages")
@MainActor
struct TeamPackageTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        return store
    }

    @Test("a team survives export and import, with routines paused and approvals back on")
    func roundTrip() throws {
        let source = makeStore()
        let chief = source.createBot(name: "Chief", title: "Orchestrator", instructions: "Coordinate. Use key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 never.")
        source.setChiefOfStaff(chief.id, enabled: true)
        let writer = source.createBot(name: "Writer", title: "Drafts")
        _ = source.createGroup(name: "Desk", memberIds: [chief.id, writer.id])
        _ = source.createRoutine(botId: writer.id, name: "Morning draft", prompt: "Draft the digest.", cron: "0 8 * * *")
        if let idx = source.bots.firstIndex(where: { $0.id == writer.id }) { source.bots[idx].autoApprove = true }

        let markdown = source.exportTeamPackage(name: "Newsroom", summary: "Two bots.").markdown()
        #expect(markdown.contains("# Newsroom"))
        #expect(!markdown.contains("sk-ant-api03-abcdefghij"))

        let package = try TeamPackage.parse(markdown: markdown)
        #expect(package.bots.count == 2 && package.rooms.count == 1 && package.routines.count == 1)
        #expect(package.preview().contains("paused"))

        let target = makeStore()
        let before = target.bots.count
        let created = target.importTeamPackage(package)
        #expect(created.count == 2)
        #expect(target.bots.count == before + 2)
        #expect(target.bots.first(where: { $0.name == "Chief" })?.chiefOfStaff == true)
        #expect(target.bots.first(where: { $0.name == "Writer" })?.autoApprove == false)
        #expect(target.groups.contains { $0.name == "Desk" })
        let imported = target.routines(for: created.first(where: { $0.name == "Writer" })!.id)
        #expect(imported.count == 1 && imported[0].active == false)
    }

    @Test("importing twice never collides on names")
    func uniqueNames() throws {
        let store = makeStore()
        _ = store.createBot(name: "Writer", title: "")
        let package = TeamPackage(name: "T", bots: [
            .init(name: "Writer", title: "", description: "", instructions: "", skills: [], tools: [], chiefOfStaff: false, goal: nil),
        ])
        store.importTeamPackage(package)
        store.importTeamPackage(package)
        let names = store.bots.map(\.name)
        #expect(names.filter { $0.hasPrefix("Writer") }.count == 3)
        #expect(Set(names).count == names.count)
    }

    @Test("unrelated, newer, damaged, and empty files are refused with a reason")
    func refusals() {
        #expect(throws: TeamPackage.ParseError.noPackage) { try TeamPackage.parse(markdown: "# just a readme") }
        let newer = "```grizzybot-team\n{\"format\":\"grizzybot-team/9\",\"name\":\"x\",\"summary\":\"\",\"bots\":[],\"rooms\":[],\"routines\":[]}\n```"
        #expect(throws: TeamPackage.ParseError.unsupported("grizzybot-team/9")) { try TeamPackage.parse(markdown: newer) }
        let empty = TeamPackage(name: "x", bots: []).markdown()
        #expect(throws: TeamPackage.ParseError.empty) { try TeamPackage.parse(markdown: empty) }
        let broken = "```grizzybot-team\n{not json\n```"
        #expect(throws: (any Error).self) { try TeamPackage.parse(markdown: broken) }
    }
}

@Suite("Scrubber coverage")
struct ScrubberCoverageTests {
    @Test("common provider key shapes are redacted", arguments: [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-proj-AbCdEf1234567890abcdef",
        "ghp_abcdefghijklmnopqrstuvwxyz0123",
        "xoxb-1234567890-abcdefghij",
        "AKIAABCDEFGHIJKLMNOP",
    ])
    func keys(_ key: String) {
        let out = DiagnosticScrubber.redact("here it is: \(key) thanks")
        #expect(!out.contains(String(key.dropFirst(6))), "\(out)")
    }
}
