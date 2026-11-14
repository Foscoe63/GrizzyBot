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

    @Test("connectors and departments round-trip and the checklist splits connected from missing")
    func connectorsAndDepartments() throws {
        let package = TeamPackage(
            name: "Agency",
            bots: [.init(name: "Ann"), .init(name: "Ben"), .init(name: "Cy")],
            routines: [.init(bot: "Cy", name: "Weekly", prompt: "Report.", cron: "0 9 * * 1")],
            connectors: [.init(slug: "gmail", name: "Gmail", why: "Reads the inbox", required: true), .init(slug: "slack", name: "Slack")],
            departments: [.init(name: "Sales", bots: ["Ann", "Ben"]), .init(name: "Ops", bots: ["Cy"])]
        )
        let md = package.markdown()
        #expect(md.contains("- [ ] Gmail (needed)"))
        let parsed = try TeamPackage.parse(markdown: md)
        #expect(parsed == package)
        #expect(parsed.preview().contains("2 departments"))

        let store = makeStore()
        store.connections.append(ConnectionItem(slug: "gmail", name: "Gmail", connected: true))
        let list = store.connectorChecklist(for: parsed)
        #expect(list.connected.map(\.slug) == ["gmail"])
        #expect(list.missing.contains { $0.slug == "slack" })

        let sales = parsed.restricted(toDepartments: ["sales"])
        #expect(sales.bots.map(\.name) == ["Ann", "Ben"])
        #expect(sales.routines.isEmpty && sales.departments.count == 1)

        let before = store.groups.count
        store.importTeamPackage(sales)
        #expect(store.groups.count == before + 1)
        #expect(store.groups.contains { $0.name == "Sales" })
    }

    @Test("a team file from before connectors and departments still imports")
    func oldFormatStillParses() throws {
        let old = "```grizzybot-team\n{\"format\":\"grizzybot-team/1\",\"name\":\"Old\",\"summary\":\"\",\"bots\":[{\"name\":\"A\",\"title\":\"\",\"description\":\"\",\"instructions\":\"\",\"skills\":[],\"tools\":[],\"chiefOfStaff\":false}],\"rooms\":[],\"routines\":[]}\n```"
        let package = try TeamPackage.parse(markdown: old)
        #expect(package.connectors.isEmpty && package.departments.isEmpty)
    }

    @Test("only https links are fetched")
    func httpRefused() async {
        await #expect(throws: TeamPackage.ParseError.invalid("only https links can be imported")) {
            try await TeamPackage.fetch(url: URL(string: "http://example.com/t.md")!)
        }
        await #expect(throws: TeamPackage.ParseError.invalid("only https links can be imported")) {
            try await TeamPackage.fetch(url: URL(string: "file:///etc/passwd")!)
        }
    }

    @Test("departments are built from per-bot labels, and rooms follow their members")
    func departmentBuilder() {
        let rooms = [TeamPackage.RoomSpec(name: "Desk", members: ["A", "B"]), .init(name: "All", members: ["A", "C"])]
        let depts = TeamPackage.departments(from: ["A": "Sales", "B": " Sales ", "C": "", "D": "Ops"], rooms: rooms, order: ["A", "B", "C", "D"])
        #expect(depts.map(\.name) == ["Sales", "Ops"])
        #expect(depts[0].bots == ["A", "B"] && depts[0].rooms == ["Desk"])
        #expect(depts[1].bots == ["D"] && depts[1].rooms.isEmpty)
    }

    @Test("exporting with labels, accounts and a chosen subset produces a department package")
    func exportWithLabels() throws {
        let store = makeStore()
        let a = store.createBot(name: "Ann", title: "")
        let b = store.createBot(name: "Ben", title: "")
        let c = store.createBot(name: "Cy", title: "")
        store.connections.append(ConnectionItem(slug: "slack", name: "Slack", connected: true))
        #expect(store.connectableAccounts.contains { $0.slug == "slack" })
        let package = store.exportTeamPackage(
            name: "Mix", botIds: [a.id, b.id],
            connectors: [.init(slug: "slack", name: "Slack", required: true)],
            departmentByBotId: [a.id: "Sales", b.id: "Sales", c.id: "Ops"]
        )
        #expect(package.bots.map(\.name) == ["Ann", "Ben"])
        #expect(package.departments.map(\.name) == ["Sales"])
        #expect(try TeamPackage.parse(markdown: package.markdown()) == package)
    }

    @Test("restricting keeps ungrouped bots only when asked")
    func ungrouped() {
        let package = TeamPackage(
            name: "T", bots: [.init(name: "A"), .init(name: "B"), .init(name: "Free")],
            routines: [.init(bot: "Free", name: "r", prompt: "p", cron: "")],
            departments: [.init(name: "One", bots: ["A"]), .init(name: "Two", bots: ["B"])]
        )
        #expect(package.ungroupedBots.map(\.name) == ["Free"])
        #expect(package.restricted(toDepartments: ["One"]).bots.map(\.name) == ["A"])
        let withFree = package.restricted(toDepartments: ["One"], includeUngrouped: true)
        #expect(withFree.bots.map(\.name) == ["A", "Free"] && withFree.routines.count == 1)
    }

    @Test("a proposed team creates nothing until confirmed, and confirmation can pick departments")
    func reviewThenImport() {
        let store = makeStore()
        let before = store.bots.count
        let package = TeamPackage(
            name: "T", bots: [.init(name: "A"), .init(name: "B")],
            departments: [.init(name: "One", bots: ["A"]), .init(name: "Two", bots: ["B"])]
        )
        store.proposeTeam(package)
        #expect(store.bots.count == before && store.pendingTeamPackage != nil)
        let made = store.confirmPendingTeam(departments: ["Two"])
        #expect(made.map(\.name) == ["B"])
        #expect(store.bots.count == before + 1)
        store.dismissPendingTeam()
        #expect(store.pendingTeamPackage == nil)
        #expect(store.confirmPendingTeam().isEmpty)
    }

    @Test("a team file loads from disk, and an oversized or foreign file is refused")
    func fileLoading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("team-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("a.team.md")
        try TeamPackage(name: "Disk", bots: [.init(name: "A")]).markdown().write(to: good, atomically: true, encoding: .utf8)
        #expect(try TeamPackage.load(file: good).name == "Disk")
        let notes = dir.appendingPathComponent("notes.md")
        try "# just notes".write(to: notes, atomically: true, encoding: .utf8)
        #expect(throws: TeamPackage.ParseError.noPackage) { try TeamPackage.load(file: notes) }
        let big = dir.appendingPathComponent("big.md")
        try String(repeating: "x", count: TeamPackage.maxDownloadBytes + 1).write(to: big, atomically: true, encoding: .utf8)
        #expect(throws: TeamPackage.ParseError.invalid("the file is too large")) { try TeamPackage.load(file: big) }
    }
}

@Suite("Team library")
@MainActor
struct TeamLibraryTests {
    @Test("every built-in team survives a round trip and imports with only real tools and skills")
    func startersAreSound() throws {
        let valid = Set(AgentToolCatalog.allIds)
        for team in TeamLibrary.starters {
            #expect(try TeamPackage.parse(markdown: team.markdown()) == team, "\(team.name)")
            let names = Set(team.bots.map(\.name))
            #expect(names.count == team.bots.count, "\(team.name) has duplicate bot names")
            for bot in team.bots { #expect(Set(bot.tools).isSubset(of: valid), "\(team.name)/\(bot.name)") }
            for room in team.rooms { #expect(Set(room.members).isSubset(of: names)) }
            for r in team.routines { #expect(names.contains(r.bot)) }
            for d in team.departments { #expect(Set(d.bots).isSubset(of: names)) }
            #expect(team.bots.filter(\.chiefOfStaff).count <= 1)
            #expect(TeamLibrary.entry(for: team).bots == team.bots.count)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        let before = store.bots.count
        store.importTeamPackage(TeamLibrary.starters[2].restricted(toDepartments: ["Briefing"]))
        #expect(store.bots.count == before + 1)
    }

    @Test("an index drops duplicates and blanks, and refuses other formats")
    func indexParsing() throws {
        let json = """
        {"format":"grizzybot-team-index/1","teams":[
          {"id":"a","name":"A","summary":"s","url":"teams/a.team.md","bots":2,"tags":["x"]},
          {"id":"a","name":"Dup","summary":"","bots":1,"tags":[]},
          {"id":"","name":"NoId","summary":"","bots":1,"tags":[]},
          {"id":"b","name":"B","summary":"","bots":1,"tags":[]}]}
        """
        let index = try TeamLibraryIndex.parse(json)
        #expect(index.teams.map(\.id) == ["a", "b"])
        #expect(throws: TeamPackage.ParseError.unsupported("other/2")) { try TeamLibraryIndex.parse("{\"format\":\"other/2\",\"teams\":[]}") }
        #expect(throws: (any Error).self) { try TeamLibraryIndex.parse("nope") }
    }

    @Test("index addresses must be https")
    func indexHttps() async {
        await #expect(throws: TeamPackage.ParseError.invalid("only https links can be imported")) {
            try await TeamLibraryIndex.fetch(url: URL(string: "http://example.com/index.json")!)
        }
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
