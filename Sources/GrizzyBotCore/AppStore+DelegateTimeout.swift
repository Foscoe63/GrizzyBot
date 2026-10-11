import Foundation

/// A bot handed a job by another bot cannot run forever. Past `delegateTimeout` its run is stopped
/// and the lead is told it failed, with the same notice any other failed handoff gets.
extension AppStore {
    func armDelegateTimeout(entryId: String, after seconds: TimeInterval? = nil) {
        let limit = seconds ?? delegateTimeout
        guard limit > 0 else { return }
        delegateTimers[entryId]?.cancel()
        delegateTimers[entryId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.enforceDelegateTimeout(entryId: entryId)
        }
    }

    public func enforceDelegateTimeout(entryId: String) {
        delegateTimers.removeValue(forKey: entryId)
        // `needsUser` counts: a job that paused for an approval and was resumed is still the lead's
        // job in flight.
        guard let entryIdx = botChat.firstIndex(where: { $0.id == entryId }),
              botChat[entryIdx].outcome == .sent || botChat[entryIdx].outcome == .needsUser,
              botChat[entryIdx].reportedAt == nil else { return }
        let entry = botChat[entryIdx]
        let key = threadKey(for: entry.toBotId)
        guard let status = threads[key]?.run?.status else { return }
        switch status {
        case .queued, .leased, .running:
            let minutes = max(1, Int((delegateTimeout / 60).rounded()))
            threads[key]?.run?.error = "it was still working after \(minutes) minutes, so it was stopped."
            stopRun(botId: entry.toBotId)
            botChat[entryIdx].outcome = .sent // so the lead is told how it ended
            flushDelegationReports()
        case .waitingInput, .waitingTakeover:
            // Held up for the person, not stuck: give it another full period once they answer.
            armDelegateTimeout(entryId: entryId)
        case .completed, .failed, .cancelled:
            break
        }
    }
}
