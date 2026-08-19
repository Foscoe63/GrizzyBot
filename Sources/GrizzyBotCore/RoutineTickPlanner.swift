import Foundation

public enum RoutineTickPolicy {
    public static let maxConcurrent = 2

    public static func admit(dueCount: Int, activeRoutineRuns: Int) -> Int {
        max(0, min(dueCount, maxConcurrent - activeRoutineRuns))
    }

    public static func skipReason(canRunLLM: Bool) -> String? {
        canRunLLM ? nil : "Skipped — no model connected. Connect a model, then run this routine again."
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
