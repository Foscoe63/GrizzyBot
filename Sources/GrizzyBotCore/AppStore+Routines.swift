import Foundation
import Observation

// Split out of Store.swift by its MARK sections; behavior is unchanged.
extension AppStore {
    // MARK: - Routines

    public func routines(for botId: String) -> [Routine] {
        routines[botId] ?? []
    }

    public func openNewRoutine() {
        editingRoutineId = nil
        routineDraft = RoutineDraft(botId: activeBotId ?? visibleBots.first?.id ?? "")
        panel = .routine
    }

    public func openRoutine(_ routine: Routine) {
        editingRoutineId = routine.id
        routineDraft = RoutineDraft(
            name: routine.name,
            prompt: routine.prompt,
            preset: Cron.preset(fromCron: routine.cron),
            botId: routine.botId
        )
        panel = .routine
    }

    @discardableResult
    public func createRoutine(
        botId: String,
        name: String,
        prompt: String,
        cron: String,
        timezone: String = "",
        active: Bool = true,
        notify: Bool = true
    ) -> Routine {
        let targetBotId = bots.contains(where: { $0.id == botId })
            ? botId
            : (activeBotId ?? bots.first?.id ?? botId)

        // Editing: may reassign to another bot.
        if let editing = editingRoutineId {
            for (ownerId, list) in routines {
                guard let idx = list.firstIndex(where: { $0.id == editing }) else { continue }
                var updated = list[idx]
                updated.name = name
                updated.prompt = prompt
                updated.cron = cron
                updated.timezone = timezone
                updated.active = active
                updated.notify = notify
                updated.nextRunAt = Cron.nextDate(cron, from: .now, timezone: timezone)
                updated.botId = targetBotId

                if ownerId == targetBotId {
                    var next = list
                    next[idx] = updated
                    routines[ownerId] = next
                } else {
                    var fromList = list
                    fromList.remove(at: idx)
                    routines[ownerId] = fromList
                    var toList = routines[targetBotId] ?? []
                    toList.append(updated)
                    routines[targetBotId] = toList
                }
                save()
                return updated
            }
        }

        let routine = Routine(
            id: Ids.new(),
            botId: targetBotId,
            name: name,
            prompt: prompt,
            cron: cron,
            timezone: timezone,
            active: active,
            notify: notify,
            nextRunAt: Cron.nextDate(cron, from: .now, timezone: timezone)
        )
        var list = routines[targetBotId] ?? []
        list.append(routine)
        routines[targetBotId] = list
        save()
        return routine
    }

    public func saveRoutineDraft(botId: String? = nil) {
        let assigned = {
            let draftBot = routineDraft.botId
            if !draftBot.isEmpty, bots.contains(where: { $0.id == draftBot }) { return draftBot }
            if let botId, bots.contains(where: { $0.id == botId }) { return botId }
            return activeBotId ?? visibleBots.first?.id ?? ""
        }()
        guard !assigned.isEmpty else { return }

        let name = routineDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routineDraft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = createRoutine(
            botId: assigned,
            name: name.isEmpty ? "Routine" : name,
            prompt: prompt.isEmpty ? "Check in." : prompt,
            cron: Cron.fromPreset(routineDraft.preset)
        )
        editingRoutineId = nil
        panel = .computer
        if activeBotId != assigned {
            selectBot(assigned)
        }
    }

    public func assignRoutine(_ routineId: String, toBotId: String) {
        guard bots.contains(where: { $0.id == toBotId }) else { return }
        for (ownerId, list) in routines {
            guard let idx = list.firstIndex(where: { $0.id == routineId }) else { continue }
            var routine = list[idx]
            routine.botId = toBotId
            if ownerId == toBotId {
                var next = list
                next[idx] = routine
                routines[ownerId] = next
            } else {
                var fromList = list
                fromList.remove(at: idx)
                routines[ownerId] = fromList
                var toList = routines[toBotId] ?? []
                toList.append(routine)
                routines[toBotId] = toList
            }
            save()
            return
        }
    }

    public func deleteRoutine(_ routineId: String) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?.remove(at: idx)
            if editingRoutineId == routineId {
                editingRoutineId = nil
                panel = .computer
            }
            save()
            return
        }
    }

    /// Run a specific routine (OpenMausBot `/api/routines/:id/run`).
    public func runRoutine(_ routineId: String) {
        guard let botId = routines.first(where: { $0.value.contains(where: { $0.id == routineId }) })?.key,
              let routine = routines[botId]?.first(where: { $0.id == routineId }) else { return }
        fireRoutine(botId: botId, routine: routine, manual: true)
    }

    public func runNow(botId: String) {
        let list = routines[botId] ?? []
        let now = Date.now
        guard let routine = list.first(where: { $0.active && ($0.nextRunAt.map { $0 <= now } ?? true) })
            ?? list.first(where: \.active)
            ?? list.first
        else {
            openNewRoutine()
            return
        }
        fireRoutine(botId: botId, routine: routine, manual: true)
    }

    func fireRoutine(botId: String, routine: Routine, manual: Bool = false) {
        if !headlessRoutineTick {
            selectBot(botId)
            showChat()
        }
        let key = threadKey(for: botId)
        guard var thread = threads[key] ?? threads[botId] else {
            threads[botId] = ThreadData(threadId: bots.first(where: { $0.id == botId })?.threadId ?? Ids.new())
            guard var created = threads[botId] else { return }
            appendRoutineRun(botId: botId, routine: routine, thread: &created, threadKey: botId, manual: manual)
            return
        }
        appendRoutineRun(botId: botId, routine: routine, thread: &thread, threadKey: key, manual: manual)
    }

    private func appendRoutineRun(
        botId: String,
        routine: Routine,
        thread: inout ThreadData,
        threadKey: String,
        manual: Bool
    ) {
        let bot = bots.first(where: { $0.id == botId })
        if let bot, let reason = RoutineTickPolicy.skipReason(canRunLLM: canRunLLM(for: bot)) {
            let meta = ThreadMessage(
                id: Ids.new(),
                threadId: thread.threadId,
                seq: thread.nextSeq,
                role: .system,
                blocks: [.meta("Routine '\(routine.name)' skipped — no model connected")]
            )
            thread.messages.append(meta)
            thread.cursor = meta.seq
            threads[threadKey] = thread
            if let idx = routines[botId]?.firstIndex(where: { $0.id == routine.id }) {
                routines[botId]?[idx].lastRunAt = .now
                routines[botId]?[idx].nextRunAt = Cron.nextDate(
                    routine.cron,
                    from: .now,
                    timezone: routine.timezone
                )
                routines[botId]?[idx].inProgress = false
            }
            appendRunLog(botId: botId, kind: "routine", text: reason)
            save()
            return
        }

        let meta = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .system,
            blocks: [.meta("Routine '\(routine.name)' fired")]
        )
        thread.messages.append(meta)
        thread.cursor = meta.seq

        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: manual ? RoutineTrigger.manual : RoutineTrigger.scheduled,
            routineId: routine.id
        )
        thread.run = run
        threads[threadKey] = thread

        if let idx = routines[botId]?.firstIndex(where: { $0.id == routine.id }) {
            routines[botId]?[idx].lastRunAt = .now
            routines[botId]?[idx].inProgress = true
            routines[botId]?[idx].lastError = nil
        }
        save()

        let runId = run.id
        let prompt = routine.prompt
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: prompt)
        }
        runTasks[runId] = task
    }
}
