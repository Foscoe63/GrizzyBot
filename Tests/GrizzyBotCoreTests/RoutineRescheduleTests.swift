import Foundation
import GrizzyBotCore
import Testing

@Suite("Routine rescheduling")
struct RoutineRescheduleTests {
    private func utc(_ iso: String) -> Date {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: iso)!
    }

    /// Daily at 07:00 UTC. "now" in these tests is the morning of Sun 2026-09-13,
    /// so the next scheduled slot is always 2026-09-14T07:00Z.
    private func routine(
        failCount: Int = 0,
        nextRunAt: Date? = nil,
        lastError: String? = nil
    ) -> Routine {
        Routine(
            id: "r1",
            botId: "b1",
            name: "Morning-Brief",
            prompt: "brief me",
            cron: "0 7 * * *",
            timezone: "UTC",
            nextRunAt: nextRunAt,
            failCount: failCount,
            lastError: lastError
        )
    }

    private let now = Date(timeIntervalSince1970: 1_789_299_326) // 2026-09-13T11:35:26Z
    private var tomorrow: Date { utc("2026-09-14T07:00:00Z") }

    @Test("a stopped run goes back to its slot instead of retrying")
    func cancelDoesNotRetry() {
        // The bug: cancelled shared the failed branch, so stopping a run queued a
        // retry 15 minutes out — and each cancel doubled the ladder.
        let plan = RoutineTickPolicy.reschedule(
            routine(failCount: 1),
            status: .cancelled,
            manual: false,
            error: "cancelled",
            now: now
        )
        #expect(plan.nextRunAt == tomorrow)
        #expect(plan.failCount == 1) // history kept, but not advanced
        #expect(plan.lastError == "cancelled")
    }

    @Test("a failed scheduled run retries, then gives up on the ladder")
    func failedRetriesUpToTheLimit() {
        for fails in 0..<Cron.retryLimit {
            let plan = RoutineTickPolicy.reschedule(
                routine(failCount: fails),
                status: .failed,
                manual: false,
                error: "boom",
                now: now
            )
            #expect(plan.failCount == fails + 1)
            #expect(plan.nextRunAt == Cron.backoffDate(failCount: fails + 1, from: now))
            #expect(plan.nextRunAt < tomorrow)
        }
        let exhausted = RoutineTickPolicy.reschedule(
            routine(failCount: Cron.retryLimit),
            status: .failed,
            manual: false,
            error: "boom",
            now: now
        )
        #expect(exhausted.failCount == Cron.retryLimit + 1)
        #expect(exhausted.nextRunAt == tomorrow)
    }

    @Test("a completed run clears the failure and takes the next slot")
    func completedResets() {
        let plan = RoutineTickPolicy.reschedule(
            routine(failCount: 2, lastError: "boom"),
            status: .completed,
            manual: false,
            now: now
        )
        #expect(plan.nextRunAt == tomorrow)
        #expect(plan.failCount == 0)
        #expect(plan.lastError == nil)
    }

    @Test("a hand-run never adds a retry of its own")
    func manualRunDoesNotReschedule() {
        // Scheduled slot already queued for tomorrow: a manual attempt leaves it.
        let queued = routine(nextRunAt: tomorrow)
        for status in [RunStatus.failed, .cancelled, .completed] {
            let plan = RoutineTickPolicy.reschedule(queued, status: status, manual: true, error: "boom", now: now)
            #expect(plan.nextRunAt == tomorrow)
            #expect(plan.failCount == 0)
        }
    }

    @Test("a hand-run clears a pending retry when it succeeds")
    func manualSuccessClearsRetry() {
        // Retry pending in 12 minutes after an earlier failure.
        let pending = routine(failCount: 1, nextRunAt: now.addingTimeInterval(12 * 60), lastError: "boom")
        let plan = RoutineTickPolicy.reschedule(pending, status: .completed, manual: true, now: now)
        #expect(plan.nextRunAt == tomorrow) // the retry is satisfied, not left queued
        #expect(plan.failCount == 0)
        #expect(plan.lastError == nil)
    }

    @Test("a finished run never leaves nextRunAt in the past")
    func neverLeavesAnOverdueSlot() {
        // The scheduler fires on `nextRunAt <= now`; an overdue slot left behind
        // by a hand-run of an already-due routine would re-fire within seconds.
        let overdue = routine(nextRunAt: now.addingTimeInterval(-30 * 60))
        for manual in [true, false] {
            for status in [RunStatus.completed, .failed, .cancelled, .waitingInput, .waitingTakeover] {
                let plan = RoutineTickPolicy.reschedule(
                    overdue,
                    status: status,
                    manual: manual,
                    error: "boom",
                    now: now
                )
                #expect(plan.nextRunAt > now)
            }
        }
    }

    @Test("the routine's zone decides the slot")
    func timezoneDrivesTheSlot() {
        var eastern = routine()
        eastern.timezone = "America/New_York"
        let plan = RoutineTickPolicy.reschedule(eastern, status: .completed, manual: false, now: now)
        #expect(plan.nextRunAt == utc("2026-09-14T11:00:00Z")) // 07:00 EDT

        // An empty zone means this Mac, which is what the time picker shows.
        var local = routine()
        local.timezone = ""
        let localPlan = RoutineTickPolicy.reschedule(local, status: .completed, manual: false, now: now)
        #expect(localPlan.nextRunAt == Cron.nextDate("0 7 * * *", from: now))
    }

    @Test("stored UTC decodes as unset, so the clock does not shift")
    func legacyZoneDecodesAsLocal() throws {
        // Every routine on disk says "UTC" because nothing ever applied the field.
        let json = """
        {"id":"r1","botId":"b1","name":"Morning-Brief","prompt":"brief me",
         "cron":"0 7 * * *","timezone":"UTC","active":true,"notify":true}
        """
        let decoded = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        #expect(decoded.timezone.isEmpty)
        let plan = RoutineTickPolicy.reschedule(decoded, status: .completed, manual: false, now: now)
        #expect(plan.nextRunAt == Cron.nextDate("0 7 * * *", from: now))

        // A zone someone actually chose survives.
        let explicit = """
        {"id":"r2","botId":"b1","name":"n","prompt":"p","cron":"0 7 * * *","timezone":"Asia/Tokyo"}
        """
        #expect(try JSONDecoder().decode(Routine.self, from: Data(explicit.utf8)).timezone == "Asia/Tokyo")
    }
}
