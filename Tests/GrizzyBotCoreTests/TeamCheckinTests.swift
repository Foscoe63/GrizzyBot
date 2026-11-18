import XCTest
@testable import GrizzyBotCore

final class TeamCheckinTests: XCTestCase {
    func testNormalizedTimesDropsInvalidAndDuplicates() {
        XCTAssertEqual(TeamCheckin.normalizedTimes(["16:30", "9:00", "09:00", "25:00", "x"]), ["09:00", "16:30"])
    }

    func testCron() {
        XCTAssertEqual(TeamCheckin.cron(forTime: "16:30"), "30 16 * * *")
        XCTAssertNil(TeamCheckin.cron(forTime: "nope"))
    }

    func testSkipWhenRecentlyChatted() {
        let now = Date()
        XCTAssertTrue(TeamCheckin.shouldSkip(lastPersonMessage: now.addingTimeInterval(-600), now: now))
        XCTAssertFalse(TeamCheckin.shouldSkip(lastPersonMessage: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(TeamCheckin.shouldSkip(lastPersonMessage: nil, now: now))
    }

    func testComposeIncludesSnapshotAndStreakNote() {
        let snap = TeamCheckin.Snapshot(pendingApprovals: ["Ada is waiting on an approval"], recentRoutines: [], team: ["Ada"])
        let text = TeamCheckin.compose(prompt: "P", snapshot: snap, silentStreak: 3)
        XCTAssertTrue(text.contains("Ada is waiting on an approval"))
        XCTAssertTrue(text.contains("No routines ran"))
        XCTAssertTrue(text.contains("several check-ins in a row"))
        XCTAssertFalse(TeamCheckin.compose(prompt: "P", snapshot: snap, silentStreak: 0).contains("several check-ins"))
    }

    func testRoutineDecodesWithoutNewFields() throws {
        let json = #"{"id":"1","botId":"b","name":"n","cron":"0 9 * * *"}"#
        let r = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        XCTAssertFalse(r.teamCheckin)
        XCTAssertEqual(r.silentStreak, 0)
    }
}
