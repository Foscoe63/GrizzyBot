import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct DemoRecorderTests {
    @Test func typingIsOneStepAndRepeatsFold() {
        var r = DemoRecorder()
        r.add(DemoEvent(kind: .navigate, url: "https://shop.example.com/login?token=abc#x"))
        r.add(DemoEvent(kind: .navigate, url: "https://shop.example.com/login?token=zzz"))
        r.add(DemoEvent(kind: .type, label: "Search", role: "field", value: "sho"))
        r.add(DemoEvent(kind: .type, label: "Search", role: "field", value: "shoes"))
        r.add(DemoEvent(kind: .click, label: "Go", role: "button"))
        r.add(DemoEvent(kind: .click, label: "Go", role: "button"))
        #expect(r.steps.count == 3)
        #expect(r.steps[0].url == "https://shop.example.com/login")
        #expect(r.steps[1].value == "shoes")
    }

    @Test func sensitiveValuesNeverSurvive() {
        var r = DemoRecorder()
        r.add(DemoEvent(kind: .type, label: "Password", role: "field", value: "hunter2", sensitive: true))
        r.add(DemoEvent(kind: .type, label: "Notes", role: "field", value: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(r.steps.allSatisfy { $0.value.isEmpty && $0.sensitive })
        let body = DemoPlaybook.render(title: "Login", steps: r.steps).body
        #expect(!body.contains("hunter2") && !body.contains("sk-ant"))
        #expect(body.contains("request a takeover"))
        #expect(!MemoryLedger.looksLikeSecret(body), "a login demonstration must be saveable")
    }

    @Test func capAndParsing() {
        var r = DemoRecorder()
        for i in 0..<(DemoRecorder.maxSteps + 20) { r.add(DemoEvent(kind: .click, label: "b\(i)", role: "button")) }
        #expect(r.steps.count == DemoRecorder.maxSteps)
        #expect(DemoEvent.parse(["k": "click", "label": "OK", "role": "button"])?.label == "OK")
        #expect(DemoEvent.parse(["k": "nonsense"]) == nil)
        #expect(DemoEvent.parse("string") == nil)
    }

    @Test func playbookReadsAsSteps() {
        let steps = [
            DemoEvent(kind: .navigate, url: "https://shop.example.com/cart"),
            DemoEvent(kind: .click, label: "Checkout", role: "button"),
            DemoEvent(kind: .select, label: "Country", role: "menu", value: "Canada"),
        ]
        let p = DemoPlaybook.render(title: "Order shoes", steps: steps)
        #expect(p.id == "order-shoes")
        #expect(p.description.contains("shop.example.com"))
        #expect(p.body.contains("1. Go to https://shop.example.com/cart."))
        #expect(p.body.contains("2. Click the button “Checkout”."))
        #expect(p.body.contains("choose “Canada”"))
    }
}

@Suite @MainActor struct DemoStoreTests {
    @Test func recordsOnlyWhilePersonHoldsTheBrowserAndProposesASkill() throws {
        let store = AppStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)"), delayScale: 0)
        let bot = store.createBot(name: "Learner", title: "t")
        store.computers[bot.id] = ComputerStatus(botId: bot.id, state: .running)
        #expect(store.startDemo(botId: bot.id) == nil)
        #expect(store.startDemo(botId: bot.id) != nil, "one recording at a time")

        store.recordDemoEvent(botId: bot.id, DemoEvent(kind: .click, label: "Sign in", role: "button"))
        store.computers[bot.id]?.controlHolder = .bot
        store.recordDemoEvent(botId: bot.id, DemoEvent(kind: .click, label: "Bot's own click", role: "button"))
        #expect(store.demoStepCount == 1)
        store.computers[bot.id]?.controlHolder = .user

        let message = store.finishDemo(title: "Sign in to portal")
        #expect(message.hasPrefix("1 steps"), Comment(rawValue: message))
        #expect(store.skillsAwaitingReview().contains { $0.id == "sign-in-to-portal" }, Comment(rawValue: message))
        #expect(store.demoRecordingBotId == nil)
        #expect(store.finishDemo(title: "x") == "Nothing was being recorded.")
    }

    @Test func emptyRecordingMakesNoSkill() {
        let store = AppStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)"), delayScale: 0)
        let bot = store.createBot(name: "L", title: "t")
        store.computers[bot.id] = ComputerStatus(botId: bot.id, state: .running)
        store.startDemo(botId: bot.id)
        #expect(store.finishDemo(title: "Nothing").contains("Nothing was recorded"))
    }
}
