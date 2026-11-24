import Foundation

// The standing goal loop: after a turn finishes, a small judge says whether the goal is met, and the bot is sent back to
// work until it is, it is blocked on a person, or the turn budget runs out.
extension AppStore {
    /// Called when a run ends. Starts the next turn when the goal is not met.
    func afterRunGoalCheck(botId: String, threadKey: String, status: RunStatus?, provider: String?, modelId: String?, client: any ChatCompleting) {
        guard status == .completed, !headlessRoutineTick, !groups.contains(where: { $0.id == threadKey }),
              let bot = bots.first(where: { $0.id == botId }),
              let goal = bot.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty,
              (bot.goalState ?? GoalState()).status == .active else { return }
        let reply = latestBotReply(threadKey: threadKey)
        goalContinuations[botId]?.cancel()
        goalContinuations[botId] = Task { [weak self] in
            await self?.judgeGoal(botId: botId, threadKey: threadKey, goal: goal, reply: reply, provider: provider, modelId: modelId, client: client)
        }
    }

    private func judgeGoal(botId: String, threadKey: String, goal: String, reply: String, provider: String?, modelId: String?, client: any ChatCompleting) async {
        defer { goalContinuations[botId] = nil }
        guard let endpoint = try? await resolveEndpoint(provider: provider, modelId: modelId),
              let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        var state = bots[idx].goalState ?? GoalState()
        let request = ChatCompletionRequest(
            endpoint: endpoint,
            messages: [.system(GoalJudge.instructions),
                       .user(GoalJudge.prompt(goal: goal, lastReply: reply, autoTurns: state.autoTurns, budget: goalBudget))],
            timeout: 30, stallMs: 0
        )
        let verdict: GoalJudge.Verdict?
        if let response = try? await Self.withDeadline(seconds: 30, { try await client.complete(request) }) {
            verdict = GoalJudge.parse(response.text)
        } else {
            verdict = nil
        }
        // The person may have spoken, changed the goal or stopped the bot while the judge was thinking.
        guard !Task.isCancelled, bots.first(where: { $0.id == botId })?.goal == goal,
              threads[threadKey]?.run?.status.isActive != true else { return }

        guard let verdict else {
            // Fail open: keep going, but a judge that keeps failing must not drive the bot forever.
            state.judgeFailures += 1
            if state.judgeFailures >= GoalJudge.maxJudgeFailures {
                state.status = .paused
                state.note = "The goal check kept failing."
                saveGoalState(botId, state)
                postGoalNote(botId: botId, threadKey: threadKey, text: "Goal paused: the check that decides whether it is finished kept failing. `/goal resume` to carry on, or `/goal clear`.")
                return
            }
            saveGoalState(botId, state)
            await continueGoal(botId: botId, threadKey: threadKey, goal: goal, reason: "", state: &state)
            return
        }
        state.judgeFailures = 0
        switch verdict {
        case .done(let reason):
            if let i = bots.firstIndex(where: { $0.id == botId }) { bots[i].goal = nil; bots[i].goalState = nil; save() }
            postGoalNote(botId: botId, threadKey: threadKey, text: "Goal met\(reason.isEmpty ? "" : ": \(reason)"). I've cleared it.")
        case .wait(let reason):
            state.status = .waiting
            state.note = reason
            saveGoalState(botId, state)
            postGoalNote(botId: botId, threadKey: threadKey, text: "Goal on hold\(reason.isEmpty ? "" : ": \(reason)"). Send a message or `/goal resume` when it can go on.")
        case .continue(let reason):
            await continueGoal(botId: botId, threadKey: threadKey, goal: goal, reason: reason, state: &state)
        }
    }

    private func continueGoal(botId: String, threadKey: String, goal: String, reason: String, state: inout GoalState) async {
        guard state.autoTurns < goalBudget else {
            state.status = .paused
            state.note = "Used its \(goalBudget) automatic turns."
            saveGoalState(botId, state)
            postGoalNote(botId: botId, threadKey: threadKey, text: "Goal paused after \(goalBudget) automatic turns without finishing. Reply to steer me, or `/goal resume` for another \(goalBudget).")
            return
        }
        state.autoTurns += 1
        saveGoalState(botId, state)
        await sleep(goalContinuationDelay)
        guard !Task.isCancelled, bots.first(where: { $0.id == botId })?.goal == goal,
              threads[threadKey]?.run?.status.isActive != true else { return }
        goalSending = botId
        send(botId: botId, text: GoalJudge.continuation(goal: goal, reason: reason))
        goalSending = nil
    }

    /// The person wrote something: any turn the loop had lined up is dropped and the count starts again. A goal parked
    /// on a wait carries on from here.
    func noteUserMessageForGoal(botId: String) {
        guard goalSending != botId else { return }
        goalContinuations[botId]?.cancel()
        goalContinuations[botId] = nil
        guard let idx = bots.firstIndex(where: { $0.id == botId }), bots[idx].goal != nil, var state = bots[idx].goalState else { return }
        state.autoTurns = 0
        state.judgeFailures = 0
        if state.status == .waiting { state.status = .active }
        bots[idx].goalState = state
    }

    func saveGoalState(_ botId: String, _ state: GoalState) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].goalState = state
        save()
    }

    /// A short line from the bot in its thread, for what the loop decided.
    func postGoalNote(botId: String, threadKey: String, text: String) {
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        let message = ThreadMessage(id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .bot, blocks: [.text(text)])
        thread.messages.append(message)
        thread.cursor = message.seq
        threads[threadKey] = thread
    }

    /// `/goal pause`, `/goal resume`, `/goal status`; nil when the text is not one of them.
    func goalControlReply(botId: String, text: String) -> String? {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return nil }
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["pause", "resume", "status"].contains(word) else { return nil }
        guard let goal = bots[idx].goal, !goal.isEmpty else { return "No standing goal. Set one with `/goal <what you want done>`." }
        var state = bots[idx].goalState ?? GoalState()
        switch word {
        case "pause":
            state.status = .paused
            state.note = "Paused by you."
            goalContinuations[botId]?.cancel()
            saveGoalState(botId, state)
            return "Goal paused: \(goal)\n\n`/goal resume` to carry on."
        case "resume":
            state = GoalState()
            saveGoalState(botId, state)
            return nil
        default:
            let line: String
            switch state.status {
            case .active: line = "working (\(state.autoTurns) of \(goalBudget) automatic turns used)"
            case .waiting: line = "on hold\(state.note.isEmpty ? "" : ": \(state.note)")"
            case .paused: line = "paused\(state.note.isEmpty ? "" : ": \(state.note)")"
            }
            return "Standing goal: \(goal)\n\nStatus: \(line)."
        }
    }
}
