import Foundation
import Observation

// Tasks, approval and choice answers, regenerate/undo/edit/branch, and chat search.
extension AppStore {
    @discardableResult
    public func createTask(botId: String, title: String) -> BotTask? {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return nil }
        let task = BotTask(title: title.isEmpty ? "New task" : title)
        bots[idx].tasks.append(task)
        bots[idx].activeTaskId = task.id
        threads[task.id] = ThreadData(threadId: task.threadId)
        // Point bot.threadId at the task thread for chat routing.
        bots[idx].threadId = task.threadId
        if threads[botId] == nil {
            threads[botId] = ThreadData(threadId: bots[idx].threadId)
        }
        save()
        return task
    }

    public func selectTask(botId: String, taskId: String?) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let taskId, let task = bots[idx].tasks.first(where: { $0.id == taskId }) {
            bots[idx].activeTaskId = taskId
            bots[idx].threadId = task.threadId
            if threads[taskId] == nil {
                threads[taskId] = ThreadData(threadId: task.threadId)
            }
        } else {
            bots[idx].activeTaskId = nil
        }
        save()
    }

    public func messagesForActiveContext(botId: String) -> [ThreadMessage] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        if let taskId = bot.activeTaskId {
            return threads[taskId]?.messages ?? []
        }
        return threads[botId]?.messages ?? []
    }

    public func toggleReaction(botId: String, messageId: String, emoji: String) {
        let key: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var reactions = thread.messages[mIdx].reactions
        if let rIdx = reactions.firstIndex(where: { $0.emoji == emoji }) {
            reactions[rIdx].count += 1
            if reactions[rIdx].count > 3 {
                reactions.remove(at: rIdx)
            }
        } else {
            reactions.append(MessageReaction(emoji: emoji))
        }
        thread.messages[mIdx].reactions = reactions
        threads[key] = thread
        save()
    }

    public func answerApproval(botId: String, messageId: String, decision: ApprovalDecision, editedBody: String?) {
        // An edited draft replaces the message text the tool will send.
        if let editedBody, decision != .deny {
            let key = threadKey(for: botId)
            if var thread = threads[key], var pending = thread.pendingTool, pending.tool == DraftPreview.tool {
                pending.arguments = DraftPreview.applying(editedBody: editedBody, to: pending.arguments)
                thread.pendingTool = pending
                threads[key] = thread
            }
        }
        answerApproval(botId: botId, messageId: messageId, decision: decision)
    }

    public func answerApproval(botId: String, messageId: String, decision: ApprovalDecision) {
        let key = threadKey(for: botId)
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        // Only a card still waiting can be answered; a stale one (cancelled, or already answered) is inert.
        guard thread.messages[mIdx].blocks.contains(where: { if case .approval(_, _, .pending) = $0 { return true }; return false }) else { return }
        for i in thread.messages[mIdx].blocks.indices {
            if case .approval(let tool, let detail, _) = thread.messages[mIdx].blocks[i] {
                let status: ApprovalStatus
                switch decision {
                case .allow: status = .allowed
                case .deny: status = .denied
                case .alwaysAllow:
                    status = .alwaysAllowed
                    if AppStore.humanOnlyTools.contains(tool) {
                        // Allowed this once; never a standing yes for something that exists to stop standing yeses.
                    } else if let bIdx = bots.firstIndex(where: { $0.id == botId }) {
                        if AllowRule.narrows(tool: tool) {
                            // Shell and file approvals become a rule for what was approved, not a blanket yes.
                            let rule = AllowRule.suggested(tool: tool, detail: detail)
                            if !bots[bIdx].allowRules.contains(where: { $0.tool == rule.tool && $0.pattern == rule.pattern }) {
                                bots[bIdx].allowRules.append(rule)
                            }
                        } else if !bots[bIdx].alwaysAllowTools.contains(tool) {
                            bots[bIdx].alwaysAllowTools.append(tool)
                        }
                    }
                }
        thread.messages[mIdx].blocks[i] = .approval(tool: tool, detail: detail, status: status)
            }
        }
        let pending = thread.pendingTool
        thread.pendingTool = nil
        if decision == .deny {
            let follow = ThreadMessage(
                id: Ids.new(),
                threadId: thread.threadId,
                seq: thread.nextSeq,
                role: .bot,
                blocks: [.text("okay — cancelled.")]
            )
            thread.messages.append(follow)
            thread.cursor = follow.seq
            if thread.run?.status == .waitingInput {
                thread.run?.status = .completed
                thread.run?.completedAt = .now
            }
            threads[key] = thread
            if let idx = bots.firstIndex(where: { $0.id == botId }) {
                bots[idx].status = "idle"
            }
            save()
            releaseWorkingFolderOverrideIfNeeded(botId: botId)
            return
        }
        threads[key] = thread
        save()
        if let pending {
            Task { [weak self] in
                guard let self else { return }
                let dummy = ModelEndpoint(
                    provider: "injected",
                    model: "local",
                    baseURL: "https://localhost/v1",
                    apiKey: "local"
                )
                let result = await self.executeAgentTool(
                    name: pending.name,
                    argumentsJSON: pending.arguments,
                    botId: botId,
                    depth: 0,
                    endpoint: dummy,
                    client: self.chatCompleter
                        ?? Self.defaultClient(for: self.bots.first(where: { $0.id == botId })?.modelProvider
                            ?? self.modelProvider),
                    approved: true
                )
                let shown = UntrustedContent.isExternal(tool: pending.name)
                    ? UntrustedContent.wrap(result.output, tool: pending.name)
                    : result.output
                self.send(
                    botId: botId,
                    text: "Approved \(pending.tool). Tool result:\n\(shown)\nContinue the task."
                )
            }
            return
        }
        let follow = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text("okay — proceeding.")]
        )
        thread.messages.append(follow)
        thread.cursor = follow.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    public func answerChoice(botId: String, messageId: String, option: ChoiceOption) {
        let key = threadKey(for: botId)
        guard var thread = threads[key] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(option.label)]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        threads[key] = thread
        save()
        send(botId: botId, text: option.label)
        _ = messageId
    }

    public func regenerateLast(botId: String) {
        regenerateFrom(botId: botId, messageId: nil)
    }

    /// Drop replies after a user (or bot) message and run again from that prompt.
    public func regenerateFrom(botId: String, messageId: String?) {
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return }
        let user: ThreadMessage?
        if let messageId, let match = thread.messages.first(where: { $0.id == messageId }) {
            if match.role == .user {
                user = match
            } else {
                user = thread.messages.last(where: { $0.seq < match.seq && $0.role == .user })
            }
        } else {
            user = thread.messages.last(where: { $0.role == .user })
        }
        guard let user else { return }
        if let idx = thread.messages.firstIndex(where: { $0.id == user.id }) {
            thread.messages.removeSubrange((idx + 1)...)
            thread.llmMessages = []
            thread.pendingTool = nil
            threads[key] = thread
            save()
        }
        launchRun(botId: botId, threadKey: key, prompt: user.firstText)
    }

    /// Remove the last user prompt and everything after it. Returns the restored draft.
    @discardableResult
    public func undoSend(botId: String) -> String? {
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return nil }
        guard let lastUserIdx = thread.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let text = thread.messages[lastUserIdx].firstText
        thread.messages.removeSubrange(lastUserIdx...)
        thread.llmMessages = []
        thread.pendingTool = nil
        thread.run = nil
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
            bots[idx].preview = thread.messages.last?.firstText ?? ""
            bots[idx].updatedAt = .now
        }
        save()
        pendingComposerText = text
        return text
    }

    public func canUndoSend(botId: String) -> Bool {
        threads[threadKey(for: botId)]?.messages.contains(where: { $0.role == .user }) == true
    }

    public func editUserMessage(botId: String, messageId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId && $0.role == .user }) else { return }
        thread.messages[idx].blocks = [.text(trimmed)]
        thread.messages.removeSubrange((idx + 1)...)
        thread.llmMessages = []
        thread.pendingTool = nil
        threads[key] = thread
        if let botIdx = bots.firstIndex(where: { $0.id == botId }) {
            bots[botIdx].preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        }
        save()
        launchRun(botId: botId, threadKey: key, prompt: trimmed)
    }

    @discardableResult
    public func branchFromMessage(botId: String, messageId: String) -> BotTask? {
        let key = threadKey(for: botId)
        guard let source = threads[key] else { return nil }
        guard let cut = source.messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        let prefix = Array(source.messages.prefix(through: cut))
        let title = prefix.last(where: { $0.role == .user })?.firstText ?? "Branch"
        guard let task = createTask(botId: botId, title: String(title.prefix(48))) else { return nil }
        if var branched = threads[task.id] {
            branched.messages = prefix.map { message in
                var copy = message
                copy.threadId = branched.threadId
                return copy
            }
            branched.llmMessages = []
            threads[task.id] = branched
            save()
        }
        return task
    }

    public func openChatSearch() { chatSearchOpen = true }
    public func closeChatSearch() {
        chatSearchOpen = false
        highlightMessageId = nil
    }

    public func jumpToSearchHit(_ hit: ChatSearchHit) {
        if let groupId = hit.groupId {
            activeGroupId = groupId
            activeBotId = nil
            mainView = .chat
        } else if let botId = hit.botId {
            activeGroupId = nil
            selectBot(botId)
            if hit.threadKey != botId {
                selectTask(botId: botId, taskId: hit.threadKey)
            } else {
                selectTask(botId: botId, taskId: nil)
            }
        }
        highlightMessageId = hit.messageId
        chatSearchOpen = false
    }

    public func searchChats(query: String, currentThreadOnly: Bool) -> [ChatSearchHit] {
        let scope: ChatSearch.Scope = {
            if currentThreadOnly, let key = activeSessionKey { return .thread(key) }
            return .all
        }()
        return ChatSearch.hits(query: query, bots: bots, groups: groups, threads: threads, scope: scope)
    }
}
