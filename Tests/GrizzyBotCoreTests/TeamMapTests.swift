import Foundation
import GrizzyBotCore
import Testing

@Suite("Team map")
@MainActor
struct TeamMapTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        return store
    }

    private func bots(_ names: String...) -> [Bot] { names.map { Bot(id: Ids.new(), name: $0, color: "#888888", threadId: Ids.new()) } }

    @Test("sections: General first, departments in order, Chiefs apart from members, hidden bots left out")
    func sections() {
        var all = bots("Ada", "Bo", "Cy", "Di")
        all[0].chiefOfStaff = true
        all[3].hidden = true
        let state = TeamMapState(departments: ["Ops", "Empty"], assignments: [all[1].id: "Ops", all[2].id: "Ops", all[3].id: "Ops"])
        let s = TeamMapLogic.sections(bots: all, state: state)
        #expect(s.map(\.name) == ["General", "Ops", "Empty"])
        #expect(s[0].chiefs.map(\.name) == ["Ada"])
        #expect(s[1].members.map(\.name) == ["Bo", "Cy"])
        #expect(s[2].count == 0)
        #expect(TeamMapLogic.sections(bots: [], state: TeamMapState()).isEmpty)
        #expect(TeamMapLogic.botCountLabel(1) == "1 bot" && TeamMapLogic.botCountLabel(2) == "2 bots")
    }

    @Test("ordering and reorder")
    func ordering() {
        let b = bots("A", "B", "C")
        #expect(TeamMapLogic.orderBots(b, [b[2].id, b[0].id]).map(\.name) == ["C", "A", "B"])
        #expect(TeamMapLogic.reorder(["a", "b", "c"], moving: "c", to: 0) == ["c", "a", "b"])
        #expect(TeamMapLogic.reorder(["a", "b", "c"], moving: "a", to: 99) == ["b", "c", "a"])
        #expect(TeamMapLogic.reorder(["a"], moving: "zzz", to: 0) == ["a"])
    }

    @Test("layout: two columns, saved position wins, fit centres and never zooms in past 100%")
    func layout() {
        let b = bots("A", "B", "C")
        let state = TeamMapState(departments: ["X", "Y"], assignments: [b[1].id: "X", b[2].id: "Y"])
        let s = TeamMapLogic.sections(bots: b, state: state)
        let tiles = TeamMapLogic.layout(s, positions: [:])
        #expect(tiles[0].x == 40 && tiles[0].y == 40)
        #expect(tiles[1].x > tiles[0].x && tiles[1].y == 40)
        #expect(tiles[2].x == 40 && tiles[2].y > tiles[0].y)
        let moved = TeamMapLogic.layout(s, positions: ["X": CanvasPoint(x: 500, y: 7)])
        #expect(moved[1].x == 500 && moved[1].y == 7)
        let v = TeamMapLogic.fit(tiles, width: 4000, height: 4000)
        #expect(v.scale == 1)
        #expect(TeamMapLogic.fit(tiles, width: 100, height: 100).scale == TeamMapLogic.minScale)
        let z = TeamMapLogic.zoom(TeamMapTransform(x: 10, y: 10, scale: 1), to: 99, around: CanvasPoint(x: 0, y: 0))
        #expect(z.scale == TeamMapLogic.maxScale)
    }

    @Test("card positions and drop targets")
    func hitTesting() {
        var b = bots("Chief", "M1", "M2")
        b[0].chiefOfStaff = true
        let s = TeamMapLogic.sections(bots: b, state: TeamMapState())[0]
        let tile = TeamMapLogic.layout([s], positions: [:])[0]
        let o = TeamMapLogic.cardOrigins(s, in: tile)
        #expect(o[b[1].id]!.x > o[b[0].id]!.x)
        #expect(o[b[2].id]!.y > o[b[1].id]!.y)
        #expect(TeamMapLogic.department(at: CanvasPoint(x: tile.x + 5, y: tile.y + 5), tiles: [tile]) == "")
        #expect(TeamMapLogic.department(at: CanvasPoint(x: -50, y: -50), tiles: [tile]) == nil)
        // Dropping M2 above M1's midpoint puts it first; below everything puts it last.
        #expect(TeamMapLogic.insertionIndex(of: b[2], in: s, tile: tile, y: tile.y) == 0)
        #expect(TeamMapLogic.insertionIndex(of: b[1], in: s, tile: tile, y: tile.y + 10_000) == 1)
    }

    @Test("tags: bots, departments, @everyone, longest name wins, no match inside a longer word")
    func tags() {
        let b = bots("Maya", "Maya Jr", "Theo")
        let state = TeamMapState(departments: ["Ops"], assignments: [b[2].id: "Ops"])
        let t = TeamMapLogic.targets(text: "@Maya Jr and @Ops please review", bots: b, state: state)
        #expect(t.botIds == [b[1].id, b[2].id])
        #expect(t.words == "and please review")
        #expect(TeamMapLogic.targets(text: "@Mayank hi", bots: b, state: state).botIds.isEmpty)
        #expect(TeamMapLogic.targets(text: "mail@Maya.com", bots: b, state: state).botIds.isEmpty)
        let all = TeamMapLogic.targets(text: "@EVERYONE stop", bots: b, state: state)
        #expect(all.botIds.count == 3 && all.hasEveryone)
        #expect(TeamMapLogic.targets(text: "no tags", bots: b, state: state).botIds.isEmpty)
    }

    @Test("@everyone goes to the Chief (General's first) plus anyone named; no Chief means everyone")
    func delivery() {
        var b = bots("Lead", "DeptLead", "Theo")
        b[0].chiefOfStaff = true
        b[1].chiefOfStaff = true
        let state = TeamMapState(departments: ["Ops"], assignments: [b[1].id: "Ops"])
        let t = TeamMapLogic.targets(text: "@everyone @Theo go", bots: b, state: state)
        let d = TeamMapLogic.delivery(for: t, bots: b, state: state)
        #expect(d.chief?.name == "Lead")
        #expect(d.botIds == [b[0].id, b[2].id])
        b[0].chiefOfStaff = false; b[1].chiefOfStaff = false
        let none = TeamMapLogic.delivery(for: TeamMapLogic.targets(text: "@everyone", bots: b, state: state), bots: b, state: state)
        #expect(none.chief == nil && none.botIds.count == 3)
        #expect(TeamMapLogic.sentSummary(["a", "b", "c"]).more == 0)
        #expect(TeamMapLogic.sentSummary(["a", "b", "c", "d"]) == (["a", "b"], 2))
    }

    @Test("departments: create, duplicate refused, rename carries bots and layout, delete keeps bots")
    func departments() {
        let store = makeStore()
        let a = store.createBot(name: "Ada"), b = store.createBot(name: "Bo")
        #expect(store.createDepartment("Ops", botIds: [a.id]))
        #expect(!store.createDepartment("ops"))
        #expect(!store.createDepartment("General"))
        #expect(!store.createDepartment("   "))
        store.setDepartmentPosition("Ops", CanvasPoint(x: 9, y: 9))
        store.arrangeBot(a.id, toIndex: 0)
        #expect(store.renameDepartment("Ops", to: "Operations"))
        #expect(store.department(of: a.id) == "Operations")
        #expect(store.teamMap.positions["Operations"] == CanvasPoint(x: 9, y: 9) && store.teamMap.positions["Ops"] == nil)
        store.moveBot(b.id, toDepartment: "Operations")
        store.deleteDepartment("Operations")
        #expect(store.department(of: a.id) == "" && store.department(of: b.id) == "")
        #expect(store.bots.contains { $0.id == a.id } && store.bots.contains { $0.id == b.id })
        #expect(store.teamMap.departments.isEmpty)
        store.setDepartmentPosition("X", CanvasPoint(x: .infinity, y: 0))
        #expect(store.teamMap.positions["X"] == nil)
    }

    @Test("moving a bot drops it from its old ordering")
    func moveClearsOrder() {
        let store = makeStore()
        let a = store.createBot(name: "Ada"), b = store.createBot(name: "Bo")
        store.createDepartment("Ops", botIds: [a.id, b.id])
        store.arrangeBot(b.id, toIndex: 0)
        #expect(store.teamMap.botOrders["Ops"]?.first == b.id)
        store.moveBot(b.id, toDepartment: "")
        #expect(store.teamMap.botOrders["Ops"]?.contains(b.id) == false)
    }

    @Test("an older workspace without a team map still opens, and the map round-trips")
    func persistence() throws {
        let old = #"{"bots":[],"threads":{}}"#.data(using: .utf8)!
        let ws = try JSONDecoder().decode(UserWorkspace.self, from: old)
        #expect(ws.teamMap == TeamMapState())
        let state = TeamMapState(departments: ["Ops"], assignments: ["x": "Ops"], positions: ["Ops": CanvasPoint(x: 1, y: 2)],
                                 botOrders: ["Ops": ["x"]], showScreens: true)
        let back = try JSONDecoder().decode(TeamMapState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
        #expect(try JSONDecoder().decode(TeamMapState.self, from: "{}".data(using: .utf8)!) == TeamMapState())
    }

    @Test("the page switch and the screens toggle persist")
    func page() {
        let store = makeStore()
        store.showTeamMapPage()
        #expect(store.mainView == .teamMap)
        store.setShowScreens(true)
        #expect(store.teamMap.showScreens)
        store.showChat()
        #expect(store.mainView == .chat)
    }
}
