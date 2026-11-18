import Foundation
import GrizzyBotCore
import Testing

@Suite("Config history")
struct ConfigHistoryTests {
    @Test("a change records old and new values, and secrets are never stored")
    func diff() throws {
        let old = AppConfig()
        var new = old
        new.agentStallTimeoutMs = 90_000
        new.braveSearchKey = "super-secret-value"
        let change = try #require(ConfigHistory.diff(old: old, new: new))
        let stall = try #require(change.items.first { $0.key == "agentStallTimeoutMs" })
        #expect(stall.after == .number(90_000) && stall.before == .number(Double(old.agentStallTimeoutMs)))
        let secret = try #require(change.items.first { $0.key == "braveSearchKey" })
        #expect(secret.secret && secret.before == nil && secret.after == nil)
        #expect(ConfigHistory.diff(old: old, new: old) == nil)
    }

    @Test("reverting restores plain values and leaves secrets alone")
    func revert() throws {
        let old = AppConfig()
        var new = old
        new.agentStallTimeoutMs = 90_000
        new.braveSearchKey = "keep-me"
        let change = try #require(ConfigHistory.diff(old: old, new: new))
        let back = try #require(ConfigHistory.reverted(change, from: new))
        #expect(back.agentStallTimeoutMs == old.agentStallTimeoutMs)
        #expect(back.braveSearchKey == "keep-me")
    }

    @Test("history is capped")
    func cap() throws {
        var history: [ConfigChange] = []
        var config = AppConfig()
        for i in 0..<(ConfigHistory.cap + 5) {
            var next = config
            next.agentStallTimeoutMs = 1_000 + i
            history = ConfigHistory.appending(history, try #require(ConfigHistory.diff(old: config, new: next)))
            config = next
        }
        #expect(history.count == ConfigHistory.cap)
    }
}
