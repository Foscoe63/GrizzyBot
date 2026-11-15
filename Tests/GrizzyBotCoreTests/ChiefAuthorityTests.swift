import Foundation
@testable import GrizzyBotCore
import Testing

@Suite("Chief authority")
@MainActor
struct ChiefAuthorityTests {
    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        return store
    }

    @discardableResult
    private func add(_ store: AppStore, _ name: String, in dept: String = "", chief: Bool = false) -> Bot {
        var bot = Bot(id: Ids.new(), name: name, color: "#888888", threadId: Ids.new())
        bot.chiefOfStaff = chief
        store.bots.append(bot)
        if !dept.isEmpty { store.moveBot(bot.id, toDepartment: dept) }
        return bot
    }

    @Test("a Chief has authority over its own department and the ones it was given, never over itself, another Chief or an outsider")
    func rule() {
        let store = makeStore()
        store.createDepartment("Ops"); store.createDepartment("Legal")
        let chief = add(store, "Maus", in: "Ops", chief: true)
        let inOps = add(store, "Ada", in: "Ops")
        let inLegal = add(store, "Bo", in: "Legal")
        let inGeneral = add(store, "Cy")
        #expect(store.hasAuthority(chief.id, over: inOps.id))
        #expect(!store.hasAuthority(chief.id, over: inLegal.id))
        #expect(!store.hasAuthority(chief.id, over: inGeneral.id))
        #expect(!store.hasAuthority(chief.id, over: chief.id))
        // A plain bot never has authority, even over its own department.
        #expect(!store.hasAuthority(inOps.id, over: add(store, "Di", in: "Ops").id))
        #expect(store.setManagedDepartments(chief.id, ["Legal"]))
        #expect(store.hasAuthority(chief.id, over: inLegal.id))
        #expect(!store.hasAuthority(chief.id, over: inGeneral.id))
        // Authority is read from where a bot is now.
        store.moveBot(inLegal.id, toDepartment: "")
        #expect(!store.hasAuthority(chief.id, over: inLegal.id))
    }

    @Test("only a Chief can be given departments; unknown names and its own department are dropped")
    func setting() {
        let store = makeStore()
        store.createDepartment("Ops"); store.createDepartment("Legal")
        let chief = add(store, "Maus", in: "Ops", chief: true)
        let plain = add(store, "Ada")
        #expect(!store.setManagedDepartments(plain.id, ["Ops"]))
        #expect(store.setManagedDepartments(chief.id, ["Legal", "Ops", "Nowhere", "Legal"]))
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Legal"])
    }

    @Test("a Chief in charge of every department gets each new one; one in charge of only some does not")
    func autoGrant() {
        let store = makeStore()
        let chief = add(store, "Maus", chief: true)
        store.createDepartment("Ops")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Ops"])
        store.createDepartment("Legal")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Ops", "Legal"])
        // The person unticks one; the next new department is not added.
        store.setManagedDepartments(chief.id, ["Ops"])
        store.createDepartment("Sales")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Ops"])
    }

    @Test("rename follows, delete drops, and the setting round-trips and tolerates old files")
    func lifecycle() throws {
        let store = makeStore()
        let chief = add(store, "Maus", chief: true)
        store.createDepartment("Ops")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Ops"])
        store.renameDepartment("Ops", to: "Platform")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == ["Platform"])
        store.deleteDepartment("Platform")
        #expect(store.bots.first { $0.id == chief.id }?.managedDepartments == [])
        var b = chief; b.managedDepartments = ["X"]
        #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(b)).managedDepartments == ["X"])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chief)) as! [String: Any]
        json["managedDepartments"] = nil
        #expect(try JSONDecoder().decode(Bot.self, from: JSONSerialization.data(withJSONObject: json)).managedDepartments == [])
    }

    @Test("the Chief is told what it answers for; nobody else is; the refusal names the department and the one fix")
    func notes() {
        let store = makeStore()
        store.createDepartment("Ops"); store.createDepartment("Legal")
        let chief = add(store, "Maus", in: "Ops", chief: true)
        let ada = add(store, "Ada")
        let bo = add(store, "Bo", in: "Legal")
        #expect(store.authorityNote(forBot: ada.id) == "")
        let note = store.authorityNote(forBot: chief.id)
        #expect(note.contains("\"Ops\"") && !note.contains("\"Legal\""))
        let why = store.authorityRefusal(chief: chief, target: bo)
        #expect(why.contains("Legal") && why.contains("Also in charge of"))
        #expect(store.authorityRefusal(chief: chief, target: add(store, "Cy", chief: true)).contains("Chief of Staff"))
    }

    @Test("a bot made by a bot is filed in its creator's department")
    func spawn() async {
        let store = makeStore()
        store.createDepartment("Ops")
        let creator = add(store, "Maus", in: "Ops", chief: true)
        let result = await store.executeAgentTool(
            name: "spawn_bot", argumentsJSON: #"{"name":"Helper"}"#, botId: creator.id, depth: 0,
            endpoint: ModelEndpoint(provider: "p", model: "m", baseURL: "https://localhost", apiKey: ""),
            client: ByBotClient([:]), taint: RunTaint()
        )
        _ = result
        let child = store.bots.first { $0.name == "Helper" }
        #expect(child != nil)
        #expect(child.map { store.department(of: $0.id) } == "Ops")
    }

    private func run(_ store: AppStore, _ tool: String, _ args: String, as botId: String) async -> String {
        await store.executeAgentTool(
            name: tool, argumentsJSON: args, botId: botId, depth: 0,
            endpoint: ModelEndpoint(provider: "p", model: "m", baseURL: "https://localhost", apiKey: ""),
            client: ByBotClient([:]), taint: RunTaint()
        ).output
    }

    @Test("delete_bot: a Chief may delete in a department it is in charge of, is refused elsewhere with the reason, and a plain bot still only its own children")
    func deleteGate() async {
        let store = makeStore()
        store.createDepartment("Ops"); store.createDepartment("Legal")
        let chief = add(store, "Maus", in: "Ops", chief: true)
        let ops = add(store, "Ada", in: "Ops")
        let legal = add(store, "Bo", in: "Legal")
        let refused = await run(store, "delete_bot", #"{"name":"Bo"}"#, as: chief.id)
        #expect(refused.contains("Legal") && refused.contains("Also in charge of"))
        #expect(store.bots.contains { $0.id == legal.id })
        store.setManagedDepartments(chief.id, ["Legal"])
        #expect(await run(store, "delete_bot", #"{"name":"Bo"}"#, as: chief.id) == "Deleted bot Bo.")
        #expect(await run(store, "delete_bot", #"{"name":"Ada"}"#, as: chief.id) == "Deleted bot Ada.")
        #expect(!store.bots.contains { $0.id == ops.id || $0.id == legal.id })
        // A plain bot cannot delete a peer it did not create, whatever department it is in.
        let a = add(store, "Di"), b = add(store, "Ed")
        #expect(await run(store, "delete_bot", #"{"name":"Ed"}"#, as: a.id) == "You can only delete bots you spawned.")
        #expect(store.bots.contains { $0.id == b.id })
        // Nobody deletes the Chief this way.
        let other = add(store, "Zed", chief: true)
        #expect(await run(store, "delete_bot", #"{"name":"Zed"}"#, as: chief.id).contains("Chief of Staff"))
        _ = other
    }

    @Test("stop_bot without an open job: refused for a Chief outside its departments, with the reason")
    func stopGate() async {
        let store = makeStore()
        store.createDepartment("Legal")
        let chief = add(store, "Maus", chief: true)
        add(store, "Bo", in: "Legal")
        store.setManagedDepartments(chief.id, [])
        let said = await run(store, "stop_bot", #"{"name":"Bo"}"#, as: chief.id)
        #expect(said.contains("Legal") && said.contains("not in charge"))
    }

    @Test("the roster names departments only when it spans more than one")
    func roster() {
        let same = AgentLoop.PromptSection.roster([BotRosterEntry(name: "A")], isChiefOfStaff: false, canMessage: false)
        #expect(same?.contains("department:") == false)
        let mixed = AgentLoop.PromptSection.roster(
            [BotRosterEntry(name: "A", department: ""), BotRosterEntry(name: "B", department: "Legal")],
            isChiefOfStaff: false, canMessage: false)
        #expect(mixed?.contains("department: Legal") == true && mixed?.contains("department: General") == true)
    }
}
