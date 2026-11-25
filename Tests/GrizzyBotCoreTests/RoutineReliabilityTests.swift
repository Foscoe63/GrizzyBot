import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct RoutineReliabilityTests {
    @Test func latenessOnlyWhenReallyLate() {
        let now = Date()
        #expect(RoutineReliability.latenessNote(plannedAt: now.addingTimeInterval(-60), now: now) == nil)
        #expect(RoutineReliability.latenessNote(plannedAt: nil, now: now) == nil)
        let note = RoutineReliability.latenessNote(plannedAt: now.addingTimeInterval(-40 * 60), now: now)
        #expect(note?.hasPrefix("Started 40m late") == true)
    }

    @Test func durations() {
        #expect(RoutineReliability.humanDuration(125 * 60) == "2h 5m")
        #expect(RoutineReliability.humanDuration(27 * 3600) == "1d 3h")
    }

    @Test func approvalExpiry() {
        let now = Date()
        #expect(!RoutineReliability.approvalExpired(askedAt: now.addingTimeInterval(-29 * 60), now: now))
        #expect(RoutineReliability.approvalExpired(askedAt: now.addingTimeInterval(-31 * 60), now: now))
    }

    @Test func activeRoutinesAreBoundedAndLabelled() {
        var list: [Routine] = []
        for i in 0..<9 {
            list.append(Routine(id: "r\(i)", botId: "b", name: "Job \(i)", prompt: String(repeating: "x", count: 500), cron: "0 9 * * *", timezone: "UTC"))
        }
        let text = RoutineReliability.activeRoutinesSection(list) ?? ""
        #expect(text.contains("not a request to run them"))
        #expect(text.contains("…and 3 more."))
        #expect(text.count <= RoutineReliability.maxSectionChars + 200)
        #expect(RoutineReliability.activeRoutinesSection([]) == nil)
    }
}
