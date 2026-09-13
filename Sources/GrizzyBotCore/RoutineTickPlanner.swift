import Foundation

public enum RoutineTickPolicy {
    public static let maxConcurrent = 2

    public static func admit(dueCount: Int, activeRoutineRuns: Int) -> Int {
        max(0, min(dueCount, maxConcurrent - activeRoutineRuns))
    }

    public static func skipReason(canRunLLM: Bool) -> String? {
        canRunLLM ? nil : "Skipped — no model connected. Connect a model, then run this routine again."
    }

    /// What a finished run leaves behind on the routine.
    public struct Reschedule: Sendable, Equatable {
        public var nextRunAt: Date
        public var failCount: Int
        public var lastError: String?
    }

    /// Where a routine goes after a run ends.
    ///
    /// Three rules, all of them learned the hard way:
    /// - A cancel is a decision, not a fault: back to the normal slot, no retry.
    /// - Only a *scheduled* run may add a retry, and only `Cron.retryLimit` times.
    /// - `nextRunAt` is never left in the past, because the scheduler fires on
    ///   `nextRunAt <= now` and would re-run within seconds.
    public static func reschedule(
        _ routine: Routine,
        status: RunStatus,
        manual: Bool,
        error: String? = nil,
        now: Date = .now
    ) -> Reschedule {
        let scheduled = Cron.nextDate(routine.cron, from: now, timezone: routine.timezone)
        // A hand-run keeps whatever the scheduler already had queued ahead of it.
        let pending: Date = {
            guard let next = routine.nextRunAt, next > now else { return scheduled }
            return next
        }()
        switch status {
        case .completed:
            // A retry was pending only if the previous attempt failed. A manual
            // run that succeeds satisfies it, so the routine returns to its slot.
            let retryPending = routine.failCount > 0
            return Reschedule(
                nextRunAt: (manual && !retryPending) ? pending : scheduled,
                failCount: 0,
                lastError: nil
            )
        case .waitingInput, .waitingTakeover:
            return Reschedule(
                nextRunAt: manual ? pending : scheduled,
                failCount: routine.failCount,
                lastError: routine.lastError
            )
        case .cancelled:
            return Reschedule(
                nextRunAt: manual ? pending : scheduled,
                failCount: routine.failCount,
                lastError: error ?? "cancelled"
            )
        case .failed:
            guard !manual else {
                return Reschedule(nextRunAt: pending, failCount: routine.failCount, lastError: error)
            }
            let fails = routine.failCount + 1
            return Reschedule(
                nextRunAt: fails <= Cron.retryLimit
                    ? Cron.backoffDate(failCount: fails, from: now)
                    : scheduled,
                failCount: fails,
                lastError: error
            )
        case .running, .queued, .leased:
            return Reschedule(
                nextRunAt: routine.nextRunAt ?? scheduled,
                failCount: routine.failCount,
                lastError: routine.lastError
            )
        }
    }
}

public enum RoutineTickIPC {
    public static let bundleId = "com.grizzybot.app"
    public static let darwinName = "com.grizzybot.tick-routines"
    public static let notification = Notification.Name(darwinName)
}

/// Finds routines that are due without spinning up the full AppStore.
public enum RoutineTickPlanner {
    public struct DueRoutine: Sendable, Equatable {
        public var botId: String
        public var routineId: String
        public var name: String
    }

    public static func dueRoutines(in workspace: UserWorkspace, now: Date = .now) -> [DueRoutine] {
        var due: [DueRoutine] = []
        for (botId, list) in workspace.routines {
            let threadKey = botId
            if workspace.threads[threadKey]?.run?.status.isActive == true { continue }
            for routine in list where routine.active {
                guard let next = routine.nextRunAt, next <= now else { continue }
                due.append(DueRoutine(botId: botId, routineId: routine.id, name: routine.name))
            }
        }
        return due
    }
}
