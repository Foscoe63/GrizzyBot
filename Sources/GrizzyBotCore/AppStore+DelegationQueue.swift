import Foundation

/// A job handed to a bot that was busy. It waits in line and starts when the bot is free, instead of being refused or
/// pushed into the middle of what the bot is already doing.
struct QueuedDelegation: Sendable, Equatable {
    var entryId: String
    var fromBotId: String
    var toBotId: String
    /// The message the bot will be sent, already wrapped with who it is from.
    var envelope: String
    /// What the sender had read from outside, so the receiving run starts out as careful as the sender was.
    var taintSources: [String]
}

extension AppStore {
    static let maxQueuedPerPeer = 5

    /// Why a bot cannot take a new job now, or nil when it is free.
    func peerBusyReason(_ peer: Bot) -> String? {
        guard let status = threads[threadKey(for: peer.id)]?.run?.status else { return nil }
        if status.isActive { return "is already working on something" }
        if status == .waitingInput || status == .waitingTakeover { return "is waiting on the user" }
        return nil
    }

    /// Puts a job in line behind what `peer` is doing. The reply tells the sender where it stands; the finished job is
    /// reported back into the sender's thread like any other background hand-off.
    func queueDelegation(entryId: String, lead: String, peer: Bot, why: String, envelope: String, taint: RunTaint?) -> AgentToolCallResult {
        let waiting = delegationQueue[peer.id] ?? []
        guard waiting.count < Self.maxQueuedPerPeer else {
            updateBotChat(entryId, reply: nil, outcome: .failed, reported: true)
            return AgentToolCallResult(output: "\(peer.name) \(why) and already has \(waiting.count) jobs waiting. Don't add more; check_bot shows where it is, and try again later.")
        }
        delegationQueue[peer.id, default: []].append(QueuedDelegation(
            entryId: entryId, fromBotId: lead, toBotId: peer.id, envelope: envelope,
            taintSources: taint?.isTainted == true ? taint?.tainters ?? [] : []
        ))
        updateBotChat(entryId, reply: nil, outcome: .queued)
        startDelegationDrainer(peerId: peer.id)
        let ahead = waiting.count
        let place = ahead == 0 ? "next in line" : "\(ahead) job\(ahead == 1 ? "" : "s") ahead of it"
        return AgentToolCallResult(
            output: "\(peer.name) \(why), so this is queued (\(place)) and starts when it is free. You do not need to wait or ask again: when it finishes, its answer is posted back in this thread. Tell the user it is queued rather than done.",
            blocks: [.childBot(botId: peer.id, name: peer.name, title: peer.title, status: .messaged)]
        )
    }

    /// One drainer per bot: waits until the bot is free, hands it the next job, and repeats until none are left.
    func startDelegationDrainer(peerId: String) {
        guard delegationDrainers[peerId] == nil else { return }
        delegationDrainers[peerId] = Task { [weak self] in
            await self?.drainDelegations(peerId: peerId)
            self?.delegationDrainers[peerId] = nil
        }
    }

    private func drainDelegations(peerId: String) async {
        while let next = delegationQueue[peerId]?.first {
            let deadline = Date().addingTimeInterval(delegateQueueTimeout)
            var free = false
            while !Task.isCancelled {
                guard let peer = bots.first(where: { $0.id == peerId }) else { break }
                if peerBusyReason(peer) == nil { free = true; break }
                if Date() >= deadline { break }
                try? await Task.sleep(for: .seconds(delegateQueuePollInterval))
            }
            guard !Task.isCancelled else { return }
            delegationQueue[peerId]?.removeFirst()
            guard free, let peer = bots.first(where: { $0.id == peerId }),
                  botChat.first(where: { $0.id == next.entryId })?.outcome == .queued else {
                failQueuedDelegation(next, reason: free ? "that bot no longer exists." : "it stayed busy for too long.")
                continue
            }
            if !next.taintSources.isEmpty { inheritedTaint[peer.id] = next.taintSources }
            updateBotChat(next.entryId, reply: nil, outcome: .sent)
            armDelegateTimeout(entryId: next.entryId)
            send(botId: peer.id, text: next.envelope)
            // Let the run it started show as active before the next job is considered.
            try? await Task.sleep(for: .seconds(min(delegateQueuePollInterval, 0.2)))
        }
        delegationQueue[peerId] = nil
    }

    /// Tells the sender a queued job never started.
    private func failQueuedDelegation(_ job: QueuedDelegation, reason: String) {
        guard let idx = botChat.firstIndex(where: { $0.id == job.entryId }), botChat[idx].outcome == .queued else { return }
        let peerName = bots.first(where: { $0.id == job.toBotId })?.name ?? "The bot"
        botChat[idx].outcome = .failed
        botChat[idx].reportedAt = .now
        let leadKey = threadKey(for: job.fromBotId)
        if threads[leadKey]?.run?.status.isActive != true, var thread = threads[leadKey] ?? threads[job.fromBotId] {
            let message = ThreadMessage(
                id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .bot,
                blocks: [.text("\(peerName) never got to the job you queued (“\(botChat[idx].text.prefix(80))”): \(reason) Nothing was done. Hand it over again when it is free, or do it another way.")]
            )
            thread.messages.append(message)
            thread.cursor = message.seq
            threads[leadKey] = thread
        }
        save()
    }

    /// Jobs queued when the app last closed are gone with it; say so rather than leave them waiting forever.
    func expireQueuedDelegations() {
        var changed = false
        for idx in botChat.indices where botChat[idx].outcome == .queued {
            botChat[idx].outcome = .failed
            botChat[idx].reportedAt = .now
            changed = true
        }
        if changed { save() }
    }
}
