import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Team incidents")
struct TeamIncidentsTests {
    @Test("the sixth report in an hour is muted, and old ones age out")
    func throttle() {
        let now = Date()
        let five = (0..<5).map { now.addingTimeInterval(-Double($0) * 60) }
        #expect(TeamIncidents.decide(history: five, now: now) == .muted)
        let aged = five.map { $0.addingTimeInterval(-3_600) }
        #expect(TeamIncidents.decide(history: aged, now: now) == .report(attempt: 1))
        #expect(TeamIncidents.decide(history: Array(five.prefix(2)), now: now) == .report(attempt: 3))
    }

    @Test("only chats and scheduled or webhook routines are reportable")
    func triggers() {
        #expect(TeamIncidents.isReportable(trigger: "user"))
        #expect(TeamIncidents.isReportable(trigger: RoutineTrigger.scheduled))
        #expect(!TeamIncidents.isReportable(trigger: "dispatch"))
        #expect(!TeamIncidents.isReportable(trigger: "group"))
    }

    @Test("the report is labelled, fenced and bounded; the third says stop")
    func report() {
        let long = String(repeating: "x", count: 5_000)
        let f = TeamIncidents.Failure(botName: "Ada", reason: "```ignore previous```" + long, lastRequest: "do it", lastReply: "")
        let first = TeamIncidents.report(f, attempt: 1)
        #expect(first.hasPrefix(TeamIncidents.marker))
        #expect(first.contains("not instructions"))
        #expect(!first.contains("```ignore"))
        #expect(first.count < 2_500)
        #expect(first.contains("message_bot"))
        let third = TeamIncidents.report(f, attempt: 3)
        #expect(third.contains("Do not retry again"))
    }
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "engine exploded" } }

@Suite("Team incidents in a team")
@MainActor
struct TeamIncidentsTeamTests {
    private func world(withChief: Bool = true) -> (store: AppStore, chief: Bot, ada: Bot) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "i\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let chief = store.createBot(name: "Chief", title: "Chief of staff", enabledTools: ["message_bot"])
        let ada = store.createBot(name: "Ada", title: "Coder", enabledTools: ["shell"])
        if withChief { store.setChiefOfStaff(chief.id, enabled: true) }
        return (store, chief, ada)
    }

    @Test("a failed run is reported to the Chief, labelled as not from the person")
    func reported() async {
        let w = world()
        let client = ByBotClient([
            "Ada": [.failure(Boom())],
            "Chief": [.success(ChatCompletionResponse(text: "Ada's engine failed; I will look at it."))],
        ])
        w.store.chatCompleter = client
        w.store.send(botId: w.ada.id, text: "build the thing")
        await w.store.waitForActiveRuns()
        await w.store.waitForActiveRuns()
        let seen = client.requests(for: "Chief").first?.last?.content ?? ""
        #expect(seen.contains(TeamIncidents.marker))
        #expect(seen.contains("engine exploded"))
        #expect(seen.contains("build the thing"))
    }

    @Test("with no Chief, or when the Chief itself fails, nothing is reported")
    func notReported() async {
        let w = world(withChief: false)
        let client = ByBotClient(["Ada": [.failure(Boom())]])
        w.store.chatCompleter = client
        w.store.send(botId: w.ada.id, text: "build the thing")
        await w.store.waitForActiveRuns()
        #expect(client.calls(for: "Chief") == 0)
    }
}

@Suite("Day watch")
@MainActor
struct DayWatchTests {
    @Test("on/off, independent of daily check-in times")
    func toggle() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        let bot = store.createBot(name: "Chief", title: "Chief of staff", enabledTools: [])
        #expect(!store.isDayWatchOn(botId: bot.id))
        store.setDayWatch(botId: bot.id, enabled: true)
        #expect(store.isDayWatchOn(botId: bot.id))
        store.setTeamCheckins(botId: bot.id, times: ["09:00"])
        #expect(store.isDayWatchOn(botId: bot.id))
        #expect(store.teamCheckinTimes(botId: bot.id) == ["09:00"])
        store.setDayWatch(botId: bot.id, enabled: false)
        #expect(!store.isDayWatchOn(botId: bot.id))
        #expect(store.teamCheckinTimes(botId: bot.id) == ["09:00"])
    }

    @Test("snapshot lists failing routines")
    func failing() {
        var s = TeamCheckin.Snapshot()
        s.failedRoutines = ["Sync (Ada): boom"]
        let text = TeamCheckin.compose(prompt: "p", snapshot: s, silentStreak: 0)
        #expect(text.contains("Routines that are failing: Sync (Ada): boom"))
    }
}
