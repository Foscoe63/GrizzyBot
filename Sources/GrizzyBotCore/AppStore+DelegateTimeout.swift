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

    func enforceDelegateTimeout(entryId: String) {
        delegateTimers.removeValue(forKey: entryId)
        guard let entry = botChat.first(where: { $0.id == entryId }),
              entry.outcome == .sent, entry.reportedAt == nil else { return }
        let key = threadKey(for: entry.toBotId)
        guard let status = threads[key]?.run?.status else { return }
        switch status {
        case .queued, .leased, .running:
            let minutes = max(1, Int((delegateTimeout / 60).rounded()))
            threads[key]?.run?.error = "it was still working after \(minutes) minutes, so it was stopped."
            stopRun(botId: entry.toBotId)
            flushDelegationReports()
        case .waitingInput, .waitingTakeover:
            // Held up for the person, not stuck: give it another full period once they answer.
            armDelegateTimeout(entryId: entryId)
        case .completed, .failed, .cancelled:
            break
        }
    }
}
