import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct TakeoverResumeTests {
    @Test func notesDifferByOutcome() {
        #expect(TakeoverResume.note(TakeoverProgress(reason: "x", taken: true)).contains("fresh screenshot"))
        #expect(TakeoverResume.note(TakeoverProgress(reason: "x")).contains("was skipped"))
    }

    @MainActor @Test func noteIsOneShot() {
        let store = AppStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("tk-\(UUID().uuidString)"), delayScale: 0)
        store.takeoverProgress["b"] = TakeoverProgress(reason: "sign in")
        #expect(store.takeoverResumeNote(botId: "b") != nil)
        #expect(store.takeoverResumeNote(botId: "b") == nil)
    }
}
