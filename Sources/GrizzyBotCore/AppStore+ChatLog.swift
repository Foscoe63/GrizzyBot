import Foundation
import Observation

// Workspace sessions and the Bot Chat log.
extension AppStore {
    // MARK: - Chat / workspace sessions

    public var activeSessionKey: String? {
        if let groupId = activeGroupId { return groupId }
        guard let botId = activeBotId else { return nil }
        return threadKey(for: botId)
    }

    public var activeSessionTitle: String {
        if let groupId = activeGroupId {
            return groups.first(where: { $0.id == groupId })?.name ?? "Room"
        }
        if let bot = activeBot {
            if let taskId = bot.activeTaskId,
               let task = bot.tasks.first(where: { $0.id == taskId }) {
                return "\(bot.name) · \(task.title)"
            }
            return bot.name
        }
        return "Chat"
    }

    public var activeSessionMessageCount: Int {
        guard let key = activeSessionKey else { return 0 }
        return threads[key]?.messages.count ?? 0
    }

    public func clearActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
        }
        let threadId = threads[key]?.threadId ?? Ids.new()
        threads[key] = ThreadData(threadId: threadId)
        if let botId = activeBotId, key == botId, let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].preview = ""
            bots[idx].updatedAt = .now
        }
        if let groupId = activeGroupId, let gIdx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[gIdx].preview = ""
        }
        save()
    }

    /// Same as clear for the main thread; deletes a task thread entirely.
    public func deleteActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
            if let idx = bots.firstIndex(where: { $0.id == botId }),
               bots[idx].activeTaskId == key {
                bots[idx].tasks.removeAll { $0.id == key }
                bots[idx].activeTaskId = nil
                threads.removeValue(forKey: key)
                bots[idx].updatedAt = .now
                save()
                return
            }
        }
        clearActiveChat()
    }

    public func exportActiveChat() -> ChatSessionExport? {
        guard let key = activeSessionKey, let thread = threads[key] else { return nil }
        return ChatSessionExport(
            threadId: thread.threadId,
            title: activeSessionTitle,
            botId: activeGroupId == nil ? activeBotId : nil,
            groupId: activeGroupId,
            messages: thread.messages
        )
    }

    public func exportActiveChatJSON() -> Data? {
        guard let export = exportActiveChat() else { return nil }
        return try? userPersistence.encodeJSON(export)
    }

    public func exportActiveChatMarkdown() -> String {
        guard let export = exportActiveChat() else { return "" }
        var lines = [
            "# \(export.title)",
            "",
            "_Exported \(ISO8601DateFormatter().string(from: export.exportedAt))_",
            "",
        ]
        for message in export.messages {
            let speaker: String
            switch message.role {
            case .user: speaker = "You"
            case .bot: speaker = export.title
            case .system: speaker = "System"
            }
            let body = message.firstText.isEmpty ? transcriptBody(message) : message.firstText
            lines.append("**\(speaker)**")
            lines.append("")
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func chatExportFilename(json: Bool) -> String {
        let slug = activeSessionTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "·", with: "")
        return json ? "\(slug)-chat.json" : "\(slug)-chat.md"
    }

    public func importChat(_ export: ChatSessionExport) {
        guard let key = activeSessionKey else { return }
        let threadId = threads[key]?.threadId ?? export.threadId
        var thread = ThreadData(threadId: threadId, messages: export.messages)
        thread.cursor = export.messages.map(\.seq).max() ?? -1
        threads[key] = thread
        save()
    }

    @discardableResult
    public func saveWorkspaceSnapshot(name: String? = nil) -> WorkspaceSnapshotMeta? {
        guard let userId = session?.userId else { return nil }
        let ws = currentWorkspace()
        let messageCount = ws.threads.values.reduce(0) { $0 + $1.messages.count }
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        let meta = WorkspaceSnapshotMeta(
            name: {
                let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "Snapshot \(stamp)" : trimmed
            }(),
            botCount: ws.bots.count,
            messageCount: messageCount
        )
        let stripped = WorkspaceSecrets.from(workspace: ws).stripped(from: ws)
        userPersistence.saveSnapshot(WorkspaceSnapshot(meta: meta, workspace: stripped), userId: userId)
        return meta
    }

    public func listWorkspaceSnapshots() -> [WorkspaceSnapshotMeta] {
        guard let userId = session?.userId else { return [] }
        return userPersistence.listSnapshots(userId: userId)
    }

    @discardableResult
    public func restoreWorkspaceSnapshot(_ id: String) -> Bool {
        guard let userId = session?.userId,
              let snapshot = userPersistence.loadSnapshot(id: id, userId: userId) else { return false }
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        var ws = snapshot.workspace
        if let secrets = SecretStore.load(userId: userId) {
            ws = secrets.applying(to: ws)
        }
        applyWorkspace(ws)
        route = bots.isEmpty ? .onboarding : .shell
        save()
        return true
    }

    public func deleteWorkspaceSnapshot(_ id: String) {
        guard let userId = session?.userId else { return }
        userPersistence.deleteSnapshot(id: id, userId: userId)
    }

    public func exportWorkspaceJSON() -> Data? {
        guard session?.userId != nil else { return nil }
        let stripped = WorkspaceSecrets.from(workspace: currentWorkspace())
            .stripped(from: currentWorkspace())
        return try? userPersistence.encodeJSON(stripped)
    }

    public func workspaceExportFilename() -> String {
        let slug = (session?.name ?? "workspace")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(slug)-workspace.json"
    }

    /// Wipe bots, chats, routines, and files. Keeps the signed-in account.
    public func deleteWorkspace() {
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(UserWorkspace())
        route = .onboarding
        showHostPrompt = false
        save()
    }

    func transcriptBody(_ message: ThreadMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .meta(let t): return t
            case .ask(let t, _): return t
            case .card(let lines):
                return lines.map { "\($0.k): \($0.v)" }.joined(separator: "\n")
            case .subagent(_, let name, let task, let status, _, let result):
                return "[\(name) \(status.rawValue)] \(task)" + (result.map { " — \($0)" } ?? "")
            case .childBot(_, let name, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .approval(let tool, let detail, let status):
                return "[\(status.rawValue)] \(tool): \(detail)"
            case .choice(let question, _, _):
                return question
            case .connect(let name, _, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .computer(let state, let text):
                return "[\(state)] \(text)"
            case .progress(let t):
                return StreamText.visible(t)
            case .component(let payload):
                return payload.title
            case .artifact(let id, let title, let kind, let summary, let deleted):
                return deleted
                    ? "[artifact deleted] \(title) (\(id))"
                    : "[artifact \(kind.rawValue)] \(title) (\(id)) — \(summary)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - Bot Chat log

    @discardableResult
    func logBotChat(from: String, to: String, text: String) -> String {
        let entry = BotChatEntry(fromBotId: from, toBotId: to, text: text)
        botChat.append(entry)
        if botChat.count > BotChatEntry.retentionLimit {
            botChat.removeFirst(botChat.count - BotChatEntry.retentionLimit)
        }
        save()
        armDelegateTimeout(entryId: entry.id)
        return entry.id
    }

    func updateBotChat(_ id: String, reply: String?, outcome: BotChatEntry.Outcome, reported: Bool = false) {
        guard let idx = botChat.firstIndex(where: { $0.id == id }) else { return }
        if let reply, !reply.isEmpty { botChat[idx].reply = reply }
        botChat[idx].outcome = outcome
        if reported { botChat[idx].reportedAt = .now }
        save()
    }

    /// Every text block of a thread's newest bot message, not just the first.
    /// The bot's latest reply text in its main chat (used by voice calls).
    public func lastReplyText(botId: String) -> String { latestBotReply(threadKey: threadKey(for: botId)) }

    func latestBotReply(threadKey key: String) -> String {
        guard let message = threads[key]?.messages.last(where: { $0.role == .bot }) else { return "" }
        return message.blocks.compactMap { block -> String? in
            if case .text(let t) = block, !t.isEmpty { return t }
            return nil
        }.joined(separator: "\n\n")
    }

    /// Live state of a handed-off job, read from the peer's run rather than the
    /// (possibly stale) ledger outcome.
    /// A lead ending the run of a bot it handed work to. Scoped to the lead's own open handoffs, so a
    /// bot can never stop one it has no part in. The delegate is told why in a follow-up message.
    func stopDelegate(lead: String, peer: Bot, reason: String) -> String {
        guard peer.id != lead else { return "You cannot stop yourself." }
        let open = botChat.indices.filter {
            botChat[$0].fromBotId == lead && botChat[$0].toBotId == peer.id && botChat[$0].outcome == .sent
        }
        guard !open.isEmpty else {
            return "You have no open job with \(peer.name), so you can't stop it. Use message_bot to reach it."
        }
        let key = threadKey(for: peer.id)
        guard let status = threads[key]?.run?.status, status.isActive || status == .waitingInput || status == .waitingTakeover else {
            return "\(peer.name) is not running right now, so there is nothing to stop."
        }
        let leadName = bots.first(where: { $0.id == lead })?.name ?? "another bot"
        stopRun(botId: peer.id)
        // A run stopped while it waited for an approval must not keep showing that card.
        threads[key]?.pendingTool = nil
        for i in open { botChat[i].outcome = .failed; botChat[i].reportedAt = .now }
        recordAudit(type: .configurationChanged, botId: lead, tool: "stop_bot", reason: "stopped \(peer.name)", allowed: true, forwarded: true)
        save()
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        send(botId: peer.id, text: "Message from \(leadName) (a bot on this Mac):\n\nYour previous run was stopped on purpose. "
            + (why.isEmpty ? "Do not carry on with it. Acknowledge briefly." : "Reason: \(why)\nDo not carry on with it. Acknowledge briefly."))
        return "Stopped \(peer.name). It has been told why."
    }

    func delegationState(_ entry: BotChatEntry) -> String {
        let key = threadKey(for: entry.toBotId)
        switch entry.outcome {
        case .answered: return "answered"
        case .needsUser: return "needs the user"
        case .failed: return "failed"
        case .sent:
            switch threads[key]?.run?.status {
            case .queued, .leased, .running: return "still running"
            case .waitingInput, .waitingTakeover: return "waiting on the user"
            case .completed: return "finished (reply not yet reported)"
            case .failed, .cancelled: return "failed"
            case .none: return "sent"
            }
        }
    }

    /// Bots `botId` has handed work to that are still going, for the "waiting on …" line.
    public func waitingOnPeers(for botId: String) -> [PeerWait] {
        botChat.compactMap { entry -> PeerWait? in
            guard entry.fromBotId == botId, entry.reportedAt == nil, entry.outcome == .sent,
                  let peer = bots.first(where: { $0.id == entry.toBotId }),
                  let status = threads[threadKey(for: peer.id)]?.run?.status,
                  status.isActive || status == .waitingInput || status == .waitingTakeover
            else { return nil }
            return PeerWait(
                id: entry.id,
                name: peer.name,
                since: entry.createdAt,
                needsUser: status == .waitingInput || status == .waitingTakeover
            )
        }
    }

    func describePeer(_ peer: Bot) -> String {
        let key = threadKey(for: peer.id)
        guard let run = threads[key]?.run else { return "\(peer.name) has no run yet." }
        var lines = ["\(peer.name): \(run.status.rawValue)"]
        if let pending = threads[key]?.pendingTool {
            lines.append("Waiting on the user for \(pending.tool)\(pending.detail.isEmpty ? "" : " (\(pending.detail))").")
        }
        if let error = run.error, run.status == .failed { lines.append("Error: \(error)") }
        let reply = latestBotReply(threadKey: key)
        if !reply.isEmpty {
            let label = run.status.isActive ? "Latest message so far" : "Latest reply"
            lines.append("\(label):\n\(reply)")
        }
        return lines.joined(separator: "\n")
    }

    /// Tell a lead how its background handoffs ended: record the outcome, and when
    /// the lead is idle post the peer's answer into its thread so the user hears
    /// about it without having to ask.
    public func flushDelegationReports() {
        var changed = false
        for idx in botChat.indices where botChat[idx].reportedAt == nil && botChat[idx].outcome == .sent {
            let entry = botChat[idx]
            let peerKey = threadKey(for: entry.toBotId)
            guard let status = threads[peerKey]?.run?.status,
                  status == .completed || status == .failed || status == .cancelled else { continue }
            let leadKey = threadKey(for: entry.fromBotId)
            // Never write into a lead mid-run; the next finished run flushes again.
            guard threads[leadKey]?.run?.status.isActive != true,
                  var thread = threads[leadKey] ?? threads[entry.fromBotId],
                  let peer = bots.first(where: { $0.id == entry.toBotId }) else { continue }
            let reply = latestBotReply(threadKey: peerKey)
            let shortfall = status == .completed ? DelegateReport.shortfall(reply: reply) : nil
            let ok = status == .completed && shortfall == nil
            let text = ok
                ? "\(peer.name) finished the job you handed over (“\(entry.text.prefix(80))”):\n\n\(reply)"
                : DelegateReport.failureNotice(
                    peer: peer.name,
                    task: entry.text,
                    reason: shortfall ?? threads[peerKey]?.run?.error ?? "no reason recorded.",
                    lastWords: shortfall == nil ? "" : reply
                )
            let message = ThreadMessage(
                id: Ids.new(),
                threadId: thread.threadId,
                seq: thread.nextSeq,
                role: .bot,
                blocks: [.text(text)]
            )
            thread.messages.append(message)
            thread.cursor = message.seq
            threads[leadKey] = thread
            botChat[idx].outcome = ok ? .answered : .failed
            botChat[idx].reply = ok && !reply.isEmpty ? reply : nil
            botChat[idx].reportedAt = .now
            changed = true
        }
        if changed { save() }
    }

    public func showBotChatPage() {
        mainView = .botChat
        panel = nil
        activeGroupId = nil
    }

    public func clearBotChat() {
        botChat = []
        save()
    }
}
