import Foundation

/// A send that arrived while a routing decision for the same bot was still being made.
struct HeldSend {
    var text: String
    var files: [URL]
    var workingFolderOverride: String?
}

// Who should do this: capability profiles, the router, Chief of Staff dispatch, and room routing.
extension AppStore {
    // MARK: - Profiles

    /// The router's view of a bot. Tools are what is switched on for it right now, so an ability can
    /// never be claimed that the bot does not have.
    func profile(for bot: Bot) -> BotProfile {
        let enabled = Set(AgentToolCatalog.builtinIds.filter { bot.isToolEnabled($0) })
        return BotProfile(
            id: bot.id,
            name: bot.name,
            title: bot.title,
            description: bot.description,
            instructions: bot.instructions,
            tools: enabled,
            skills: skills(for: bot).map { "\($0.id) \($0.description)" },
            isChiefOfStaff: bot.chiefOfStaff
        )
    }

    /// True while a bot is doing something or waiting on the person: not a good moment to hand it more.
    func isOccupied(_ botId: String) -> Bool {
        if dispatchTasks[botId] != nil { return true }
        guard let status = threads[threadKey(for: botId)]?.run?.status else { return false }
        return status.isActive || status == .waitingInput || status == .waitingTakeover
    }

    /// Bots that may be handed work for `sender`: visible, opted in, able to run a model, and free.
    func dispatchCandidates(for sender: Bot) -> [Bot] {
        bots.filter { bot in
            bot.id != sender.id && !bot.hidden && !bot.chiefOfStaff && bot.dispatchable
                && canRunLLM(for: bot) && !isOccupied(bot.id)
        }
    }

    /// When a bot lacks a tool, name the bots that have it so it can hand that part over.
    func peerCapabilityHint(tool: String, for bot: Bot) -> String {
        guard bot.isToolEnabled("message_bot") else { return "" }
        let names = bots.filter { $0.id != bot.id && !$0.hidden && $0.isToolEnabled(tool) }.map(\.name)
        guard !names.isEmpty else { return "" }
        return "\nBots that have \(tool): \(names.prefix(5).joined(separator: ", ")). Hand them that part with message_bot instead of working around the limit."
    }

    // MARK: - Deciding

    /// Mention, then rules. Instant, free, and the same answer every time.
    func quickRoute(_ message: String, candidates: [Bot], thresholds: BotRouter.Thresholds) -> RouteDecision? {
        let profiles = candidates.map(profile(for:))
        return BotRouter.mention(in: message, candidates: profiles)
            ?? BotRouter.decide(message: message, candidates: profiles, thresholds: thresholds)
    }

    /// The optional router model. Any failure — no key, a slow answer, a malformed one — is "no opinion".
    func modelRoute(_ message: String, candidates: [Bot]) async -> RouteDecision? {
        guard let choice = appConfig.routerModel, !candidates.isEmpty else { return nil }
        let profiles = candidates.map(profile(for:))
        do {
            let cleaned = try PrivacyFilter.applyForSend(
                message,
                settings: appConfig.privacyFilter,
                logDirectory: userPersistence.root,
                logContext: "router"
            )
            let endpoint = try await resolveEndpoint(provider: choice.provider, modelId: choice.modelId)
            let client: any ChatCompleting = chatCompleter ?? Self.defaultClient(for: choice.provider)
            let request = ChatCompletionRequest(
                endpoint: endpoint,
                messages: ModelRouting.messages(for: cleaned, candidates: profiles),
                tools: [],
                timeout: 12,
                stallMs: 8_000
            )
            let response = try await Self.withDeadline(seconds: 12) { try await client.complete(request) }
            return ModelRouting.parse(response.text, candidates: profiles)
        } catch {
            return nil
        }
    }

    /// Runs `work` but gives up after `seconds`, even if `work` ignores cancellation.
    static func withDeadline<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: - Chief of Staff

    /// Called for a plain message to a bot. Returns the text to run normally, or nil when the message
    /// was handed off (or is being decided) and the caller should stop.
    func dispatchOrProceed(bot: Bot, threadKey: String, text: String, original: HeldSend) -> String? {
        guard bot.chiefOfStaff, bot.autoDispatch else { return text }
        // A leading "!" keeps the message with the Chief of Staff.
        if text.hasPrefix("!") {
            let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return rest }
        }
        let candidates = dispatchCandidates(for: bot)
        guard !candidates.isEmpty else { return text }

        if let decision = quickRoute(text, candidates: candidates, thresholds: .dispatch),
           let peer = candidates.first(where: { $0.id == decision.botId }) {
            startDispatch(from: bot, to: peer, decision: decision, text: text, threadKey: threadKey)
            return nil
        }
        guard appConfig.routerModel != nil else { return text }

        // The rules had no call to make; ask the router model, holding any further sends meanwhile.
        routingInFlight.insert(bot.id)
        Task { [weak self] in
            guard let self else { return }
            let decision = await self.modelRoute(text, candidates: candidates)
            self.routingInFlight.remove(bot.id)
            if let decision, let peer = self.bots.first(where: { $0.id == decision.botId }), !self.isOccupied(peer.id) {
                self.startDispatch(from: bot, to: peer, decision: decision, text: text, threadKey: threadKey)
            } else {
                self.submitUserTurn(botId: bot.id, threadKey: threadKey, text: text, imageJPEG: nil, workingFolderOverride: original.workingFolderOverride)
            }
            self.replayHeldSends(for: bot.id)
        }
        return nil
    }

    func replayHeldSends(for botId: String) {
        let held = routingHolds.removeValue(forKey: botId) ?? []
        for item in held {
            send(botId: botId, text: item.text, attaching: item.files, workingFolderOverride: item.workingFolderOverride)
        }
    }

    /// Hands the person's message to `peer` and brings the answer back into the Chief of Staff's thread,
    /// attributed to whoever wrote it.
    func startDispatch(from chief: Bot, to peer: Bot, decision: RouteDecision, text: String, threadKey: String) {
        guard var thread = threads[threadKey], let chiefIdx = bots.firstIndex(where: { $0.id == chief.id }) else { return }
        let userMsg = ThreadMessage(id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .user, blocks: [.text(text)])
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        let card = ThreadMessage(
            id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .bot,
            blocks: [
                .childBot(botId: peer.id, name: peer.name, title: peer.title, status: .messaged),
                .meta("Handed to \(peer.name) — \(decision.reason). Start a message with ! to keep it with \(chief.name)."),
            ]
        )
        thread.messages.append(card)
        thread.cursor = card.seq
        let run = Run(id: Ids.new(), botId: chief.id, threadId: thread.threadId, status: .running, trigger: "dispatch")
        thread.run = run
        threads[threadKey] = thread
        bots[chiefIdx].preview = String(text.prefix(80))
        bots[chiefIdx].status = "working"
        bots[chiefIdx].updatedAt = .now
        dispatchPeers[chief.id] = peer.id
        let chatId = logBotChat(from: chief.id, to: peer.id, text: text)
        appendRunLog(botId: chief.id, kind: "route", text: "→ \(peer.name) (\(decision.source.rawValue)): \(decision.reason)")
        save()

        let peerKey = self.threadKey(for: peer.id)
        let runId = run.id
        let task = Task { [weak self] in
            guard let self else { return }
            self.send(botId: peer.id, text: "Message from \(chief.name) (the chief of staff, passing on what the user just asked):\n\n\(text)")
            let status = await self.awaitPeerReply(threadKey: peerKey)
            await self.finishDispatch(
                chief: chief, peer: peer, threadKey: threadKey, peerKey: peerKey,
                runId: runId, chatId: chatId, text: text, status: status
            )
        }
        dispatchTasks[chief.id] = task
        runTasks[runId] = task
    }

    private func finishDispatch(
        chief: Bot, peer: Bot, threadKey: String, peerKey: String,
        runId: String, chatId: String, text: String, status: RunStatus?
    ) async {
        defer {
            dispatchTasks.removeValue(forKey: chief.id)
            dispatchPeers.removeValue(forKey: chief.id)
            runTasks.removeValue(forKey: runId)
            if let idx = bots.firstIndex(where: { $0.id == chief.id }) { bots[idx].status = "idle" }
        }
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        if Task.isCancelled || thread.run?.status == .cancelled { return }

        func post(_ blocks: [MessageBlock], author: String? = nil) {
            let message = ThreadMessage(
                id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .bot,
                blocks: blocks, authorBotId: author
            )
            thread.messages.append(message)
            thread.cursor = message.seq
        }
        func close(_ status: RunStatus, error: String? = nil) {
            thread.run?.status = status
            thread.run?.completedAt = .now
            thread.run?.error = error
        }

        switch status {
        case .completed:
            let reply = latestBotReply(threadKey: peerKey)
            updateBotChat(chatId, reply: reply, outcome: .answered, reported: true)
            let shown = reply.isEmpty ? "\(peer.name) finished but said nothing. Its thread has the detail." : reply
            post([.text(shown)], author: peer.id)
            // So the Chief of Staff remembers what happened when the conversation continues.
            thread.llmMessages.append(.user(text))
            thread.llmMessages.append(.assistant("[\(peer.name) handled this and answered]\n\(shown)"))
            close(.completed)
            threads[threadKey] = thread
            save()
            announceFinished(botId: chief.id, text: shown, status: .completed)
            if let chat = telegramReplyTargets.removeValue(forKey: chief.id) { telegramSend(chat, "\(peer.name): \(shown)") }
            settleQueue(botId: chief.id, threadKey: threadKey, runId: runId)

        case .waitingInput, .waitingTakeover:
            let pending = threads[peerKey]?.pendingTool
            let what = pending.map { " to approve \($0.tool)" } ?? ""
            updateBotChat(chatId, reply: nil, outcome: .needsUser, reported: true)
            post([.text("\(peer.name) stopped and needs you\(what). Answer it in \(peer.name)'s thread — I'll leave it there.")])
            thread.llmMessages.append(.user(text))
            thread.llmMessages.append(.assistant("[Handed to \(peer.name); it is waiting for the user]"))
            close(.completed)
            threads[threadKey] = thread
            save()
            settleQueue(botId: chief.id, threadKey: threadKey, runId: runId)

        case .failed, .cancelled:
            let why = threads[peerKey]?.run?.error ?? "no reason recorded"
            updateBotChat(chatId, reply: nil, outcome: .failed, reported: true)
            post([.meta("\(peer.name) couldn't finish (\(why)). \(chief.name) will take it from here.")])
            close(.completed)
            threads[threadKey] = thread
            save()
            // Don't leave the person without an answer: the Chief of Staff does it itself.
            launchRun(
                botId: chief.id, threadKey: threadKey,
                prompt: "\(text)\n\n[I handed this to \(peer.name) but it did not finish: \(why). Handle it yourself, or say what is blocking it.]"
            )

        case .queued, .leased, .running, .none:
            // Still going. Leave it to finish in its own thread; the report is posted back here.
            post([.meta("\(peer.name) is still working on it. Its answer will be posted here when it's done.")])
            thread.llmMessages.append(.user(text))
            thread.llmMessages.append(.assistant("[Handed to \(peer.name); still running]"))
            close(.completed)
            threads[threadKey] = thread
            save()
            settleQueue(botId: chief.id, threadKey: threadKey, runId: runId)
        }
    }

    /// Stop on the Chief of Staff also ends a hand-off it is waiting on.
    func cancelDispatch(chiefId: String) {
        guard let task = dispatchTasks[chiefId] else { return }
        task.cancel()
        if let peerId = dispatchPeers[chiefId] { stopRun(botId: peerId) }
        let key = threadKey(for: chiefId)
        if var thread = threads[key], thread.run?.trigger == "dispatch" {
            thread.run?.status = .cancelled
            thread.run?.completedAt = .now
            threads[key] = thread
        }
        dispatchTasks.removeValue(forKey: chiefId)
        dispatchPeers.removeValue(forKey: chiefId)
        if let idx = bots.firstIndex(where: { $0.id == chiefId }) { bots[idx].status = "idle" }
        save()
    }

    // MARK: - Rooms

    /// For a room message nobody is @mentioned in. Nil means "use the room's lead".
    func roomRoute(text: String, members: [Bot]) async -> RouteDecision? {
        let eligible = members.filter { $0.dispatchable && !$0.hidden }
        guard eligible.count >= 2 else { return nil }
        if let quick = quickRoute(text, candidates: eligible, thresholds: .room) { return quick }
        return await modelRoute(text, candidates: eligible)
    }
}

extension AppStore {
    /// Tells the room who was picked and why, so a wrong guess is easy to spot and correct with an @mention.
    func noteRoomRoute(groupId: String, decision: RouteDecision) {
        guard var thread = threads[groupId] else { return }
        let message = ThreadMessage(
            id: Ids.new(), threadId: thread.threadId, seq: thread.nextSeq, role: .system,
            blocks: [.meta("Routed to \(decision.botName) — \(decision.reason). @mention someone to ask them instead.")]
        )
        thread.messages.append(message)
        thread.cursor = message.seq
        threads[groupId] = thread
        save()
    }
}

extension AppStore {
    /// Whether any Chief-of-Staff hand-off is still being waited on.
    public var dispatchTasksIsEmptyForTesting: Bool { dispatchTasks.isEmpty }
}

extension AppStore {
    public func setGroupResponder(_ groupId: String, _ responder: GroupResponder) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].defaultResponder = responder
        save()
    }
}

extension AppStore {
    public func setAutoDispatch(_ botId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }), bots[idx].chiefOfStaff else { return }
        bots[idx].autoDispatch = enabled
        bots[idx].updatedAt = .now
        save()
    }

    public func setDispatchable(_ botId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].dispatchable = enabled
        bots[idx].updatedAt = .now
        save()
    }

    public func setRouterModel(_ choice: BotModelChoice) {
        switch choice {
        case .workspaceDefault: appConfig.routerModel = nil
        case .catalog(let provider, let modelId, _): appConfig.routerModel = ModelChoice(provider: provider, modelId: modelId)
        }
        save()
    }

    /// A bot that lost the Chief of Staff role stops dispatching.
    func clearDispatchIfNotChief() {
        for i in bots.indices where !bots[i].chiefOfStaff && bots[i].autoDispatch { bots[i].autoDispatch = false }
    }
}
