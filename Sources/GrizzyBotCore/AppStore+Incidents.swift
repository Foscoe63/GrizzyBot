import Foundation

// A broken run reaches the Chief of Staff.
extension AppStore {
    /// Called when a run has just failed. Hands the Chief a labelled report (it queues if the Chief is
    /// busy) unless the failure belongs to someone else: a stopped run, a job another bot is waiting
    /// on, the Chief's own run, or a team with no Chief.
    func reportIncident(botId: String, threadKey: String, run: Run?, reason: String) {
        guard let run, run.status == .failed, TeamIncidents.isReportable(trigger: run.trigger) else { return }
        guard let chief = bots.first(where: \.chiefOfStaff), chief.id != botId,
              let bot = bots.first(where: { $0.id == botId }) else { return }
        // A lead that handed this bot the job is told by the delegation report instead.
        if botChat.contains(where: { $0.toBotId == botId && $0.reportedAt == nil && $0.outcome == .sent }) { return }
        guard case .report(let attempt) = TeamIncidents.decide(history: incidentHistory[botId] ?? []) else {
            appendRunLog(botId: botId, kind: "error", text: "Incident not reported: too many in the last hour")
            return
        }
        incidentHistory[botId] = TeamIncidents.pruned(incidentHistory[botId] ?? []) + [.now]

        let messages = threads[threadKey]?.messages ?? []
        let request = messages.last(where: { $0.role == .user }).map(Self.plainText) ?? ""
        let source = RoutineTrigger.isRoutine(run.trigger) ? "a routine" : "a chat"
        let failure = TeamIncidents.Failure(
            botName: bot.name,
            reason: reason,
            lastRequest: request,
            lastReply: latestBotReply(threadKey: threadKey),
            source: source
        )
        appendRunLog(botId: botId, kind: "run", text: "Incident reported to \(chief.name)")
        send(botId: chief.id, text: TeamIncidents.report(failure, attempt: attempt))
    }

    private static func plainText(_ message: ThreadMessage) -> String {
        message.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }
}
