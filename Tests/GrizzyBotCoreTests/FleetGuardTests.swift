import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct FleetGuardTests {
    let current = "Be brief."

    @Test func staleEditIsRefused() {
        let r = FleetGuard.check(current: current, proposed: "New", expectedVersion: "deadbeef", ownerStarted: true, tainted: false)
        #expect(r == .stale(current: FleetGuard.version(of: current)))
        #expect(FleetGuard.check(current: current, proposed: "New", expectedVersion: "", ownerStarted: true, tainted: false) == .versionMissing(current: FleetGuard.version(of: current)))
    }

    @Test func onlyOwnerStartedCleanRuns() {
        let v = FleetGuard.version(of: current)
        #expect(FleetGuard.check(current: current, proposed: "New", expectedVersion: v, ownerStarted: false, tainted: false) == .notOwnerStarted)
        #expect(FleetGuard.check(current: current, proposed: "New", expectedVersion: v, ownerStarted: true, tainted: true) == .notOwnerStarted)
        #expect(FleetGuard.check(current: current, proposed: "New", expectedVersion: v, ownerStarted: true, tainted: false) == nil)
    }

    @Test func limits() {
        let v = FleetGuard.version(of: current)
        let huge = String(repeating: "x", count: FleetGuard.maxInstructionsChars + 1)
        #expect(FleetGuard.check(current: current, proposed: huge, expectedVersion: v, ownerStarted: true, tainted: false) == .tooLong(huge.count))
        let longButLegal = String(repeating: "x", count: FleetGuard.maxShownChars + 1)
        #expect(FleetGuard.check(current: current, proposed: longButLegal, expectedVersion: v, ownerStarted: true, tainted: false) == .notShownWhole)
        #expect(FleetGuard.check(current: current, proposed: current, expectedVersion: v, ownerStarted: true, tainted: false) == .nothingToChange)
    }

    @MainActor @Test func updateBotNeverSkipsThePerson() {
        #expect(AppStore.humanOnlyTools.contains("update_bot"))
    }
}
