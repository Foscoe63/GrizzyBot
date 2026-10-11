import Foundation

// Telegram: message your bots from a phone. The Mac polls Telegram, so nothing has to be
// reachable from the internet, and only chats the owner has paired are ever answered.
extension AppStore {
    static let telegramTokenKey = "telegram:token"

    public var telegramToken: String? {
        let token = connectionSecrets[Self.telegramTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    public var telegramPairingRequests: [TelegramPairing.Pending] {
        telegramPairing.active()
    }

    // MARK: - Setup

    /// Checks the token with Telegram, keeps it in the Keychain, and switches the link on.
    @discardableResult
    public func connectTelegram(token: String) async -> String? {
        guard isOwner else { return "Only the owner can connect Telegram." }
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Paste the token BotFather gave you." }
        do {
            let username = try await telegramAPIFactory(cleaned).getMe()
            connectionSecrets[Self.telegramTokenKey] = cleaned
            var settings = appConfig.telegram
            settings.enabled = true
            settings.botUsername = username
            appConfig.telegram = settings
            telegramNotice = nil
            save()
            await syncTelegram()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func disconnectTelegram() {
        guard isOwner else { return }
        connectionSecrets.removeValue(forKey: Self.telegramTokenKey)
        var settings = appConfig.telegram
        settings.enabled = false
        settings.botUsername = nil
        settings.allowedChatIds = []
        settings.chatBots = [:]
        appConfig.telegram = settings
        telegramReplyTargets = [:]
        telegramPairing = TelegramPairing()
        telegramTask?.cancel()
        telegramTask = nil
        save()
    }

    public func setTelegramEnabled(_ on: Bool) {
        guard isOwner else { return }
        appConfig.telegram.enabled = on
        save()
        Task { await syncTelegram() }
    }

    public func setTelegramNotifyRoutines(_ on: Bool) {
        guard isOwner else { return }
        appConfig.telegram.notifyRoutines = on
        save()
    }

    public func setTelegramDefaultBot(_ botId: String?) {
        guard isOwner else { return }
        appConfig.telegram.defaultBotId = botId
        save()
    }

    /// The owner types the code the chat was given; that chat is then allowed in.
    @discardableResult
    public func approveTelegramPairing(code: String) -> String? {
        guard isOwner else { return nil }
        guard let pending = telegramPairing.redeem(code) else { return nil }
        if !appConfig.telegram.allowedChatIds.contains(pending.chatId) {
            appConfig.telegram.allowedChatIds.append(pending.chatId)
        }
        save()
        recordAudit(
            type: .channelPairing, botId: nil, tool: "telegram",
            reason: "paired \(pending.name)", allowed: true, forwarded: false
        )
        telegramSend(pending.chatId, "Paired. You're talking to your GrizzyBot bots now — send /help to see what I can do.")
        return pending.name
    }

    public func revokeTelegramChat(_ chatId: Int64) {
        guard isOwner else { return }
        appConfig.telegram.allowedChatIds.removeAll { $0 == chatId }
        appConfig.telegram.chatBots.removeValue(forKey: String(chatId))
        telegramReplyTargets = telegramReplyTargets.filter { $0.value != chatId }
        save()
    }

    // MARK: - Polling

    func syncTelegram() async {
        // A background routine tick is a short-lived process: it must not take over the poll.
        guard appConfig.telegram.enabled, telegramToken != nil, delayScale >= 1, !headlessRoutineTick else {
            telegramTask?.cancel()
            telegramTask = nil
            return
        }
        if telegramTask != nil { return }
        telegramTask = Task { [weak self] in
            var offset = 0
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let api = await MainActor.run(body: { self?.telegramAPIForPolling() }) else { return }
                do {
                    let updates = try await api.getUpdates(offset: offset, timeout: 25)
                    backoff = 2
                    for update in updates {
                        offset = max(offset, update.updateId + 1)
                        await MainActor.run { self?.handleTelegramUpdate(update) }
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { self?.telegramNotice = error.localizedDescription }
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(60, backoff * 2)
                }
            }
        }
    }

    private func telegramAPIForPolling() -> (any TelegramAPI)? {
        guard appConfig.telegram.enabled, let token = telegramToken else {
            telegramTask = nil
            return nil
        }
        return telegramAPIFactory(token)
    }

    func telegramSend(_ chatId: Int64, _ text: String) {
        guard let token = telegramToken else { return }
        let api = telegramAPIFactory(token)
        Task { [weak self] in
            do {
                try await api.sendMessage(chatId: chatId, text: text)
            } catch {
                await MainActor.run { self?.telegramNotice = error.localizedDescription }
            }
        }
    }

    // MARK: - Incoming

    public func handleTelegramUpdate(_ update: TelegramUpdate) {
        guard update.isPrivate else { return } // groups are never answered
        let settings = appConfig.telegram
        guard settings.enabled else { return }

        guard settings.allowedChatIds.contains(update.chatId) else {
            if let code = telegramPairing.issue(chatId: update.chatId, name: update.displayName) {
                telegramNotice = "\(update.displayName) is asking to connect — code \(code)."
                telegramSend(
                    update.chatId,
                    "I don't know this chat yet. To connect it, open GrizzyBot → Settings → Telegram and enter this code within the hour: \(code)"
                )
            } else {
                telegramSend(update.chatId, "Too many chats are waiting to pair. Try again in a while.")
            }
            return
        }
        guard let raw = update.text, !raw.isEmpty else {
            telegramSend(update.chatId, "I can only read text messages for now.")
            return
        }
        recordAudit(
            type: .channelMessage, botId: nil, tool: "telegram",
            reason: "message from \(update.displayName)", allowed: true, forwarded: true
        )

        switch TelegramCommand.parse(raw) {
        case .start, .help:
            telegramSend(update.chatId, TelegramCommand.helpText)
        case .bots:
            telegramSend(update.chatId, telegramBotList(for: update.chatId))
        case .use(let name):
            guard let bot = telegramFindBot(named: name) else {
                telegramSend(update.chatId, "No bot called “\(name)”.\n\n\(telegramBotList(for: update.chatId))")
                return
            }
            appConfig.telegram.chatBots[String(update.chatId)] = bot.id
            save()
            telegramSend(update.chatId, "Now talking to \(bot.name).")
        case .status:
            telegramSend(update.chatId, telegramStatusText(for: update.chatId))
        case .stop:
            guard let bot = telegramBot(for: update.chatId) else { return }
            if threads[threadKey(for: bot.id)]?.run?.status.isActive == true {
                stopRun(botId: bot.id)
                telegramReplyTargets.removeValue(forKey: bot.id)
                telegramSend(update.chatId, "Stopped \(bot.name).")
            } else {
                telegramSend(update.chatId, "\(bot.name) isn't doing anything right now.")
            }
        case .approve:
            telegramAnswerApproval(chatId: update.chatId, decision: .allow)
        case .deny:
            telegramAnswerApproval(chatId: update.chatId, decision: .deny)
        case .message(let text):
            guard let bot = telegramBot(for: update.chatId) else {
                telegramSend(update.chatId, "There are no bots yet. Create one in GrizzyBot first.")
                return
            }
            telegramReplyTargets[bot.id] = update.chatId
            if let token = telegramToken {
                let api = telegramAPIFactory(token)
                let chat = update.chatId
                Task { await api.sendTyping(chatId: chat) }
            }
            send(botId: bot.id, text: String(text.prefix(8_000)))
        }
    }

    func telegramBot(for chatId: Int64) -> Bot? {
        let settings = appConfig.telegram
        if let id = settings.chatBots[String(chatId)], let bot = bots.first(where: { $0.id == id }) { return bot }
        if let id = settings.defaultBotId, let bot = bots.first(where: { $0.id == id }) { return bot }
        return bots.first(where: \.chiefOfStaff) ?? visibleBots.first ?? bots.first
    }

    private func telegramFindBot(named name: String) -> Bot? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return bots.first(where: { $0.name.lowercased() == needle })
            ?? bots.first(where: { $0.name.lowercased().hasPrefix(needle) })
    }

    private func telegramBotList(for chatId: Int64) -> String {
        let current = telegramBot(for: chatId)?.id
        let lines = bots.map { bot -> String in
            let marker = bot.id == current ? "▶︎" : "•"
            let title = bot.title.isEmpty ? "" : " — \(bot.title)"
            return "\(marker) \(bot.name)\(title)"
        }
        return lines.isEmpty ? "No bots yet." : "Your bots:\n" + lines.joined(separator: "\n") + "\n\nSwitch with /bot <name>."
    }

    private func telegramStatusText(for chatId: Int64) -> String {
        guard let bot = telegramBot(for: chatId) else { return "No bots yet." }
        guard let run = threads[threadKey(for: bot.id)]?.run else { return "\(bot.name) is idle." }
        switch run.status {
        case .running, .queued, .leased: return "\(bot.name) is working."
        case .waitingInput: return "\(bot.name) is waiting on you — /approve or /deny, or reply."
        case .waitingTakeover: return "\(bot.name) needs you at the computer to continue."
        case .completed: return "\(bot.name) is idle (last run finished)."
        case .failed: return "\(bot.name) is idle (last run failed)."
        case .cancelled: return "\(bot.name) is idle (last run stopped)."
        }
    }

    private func telegramAnswerApproval(chatId: Int64, decision: ApprovalDecision) {
        guard let bot = telegramBot(for: chatId) else { return }
        let key = threadKey(for: bot.id)
        let waiting = threads[key]?.messages.last(where: { message in
            message.blocks.contains { block in
                if case .approval(_, _, .pending) = block { return true }
                return false
            }
        })
        guard let waiting else {
            telegramSend(chatId, "Nothing is waiting on an approval.")
            return
        }
        telegramReplyTargets[bot.id] = chatId
        answerApproval(botId: bot.id, messageId: waiting.id, decision: decision)
        telegramSend(chatId, decision == .deny ? "Denied." : "Approved — continuing.")
    }

    // MARK: - Outgoing

    /// Called when a run stops. Sends the answer to the chat that asked, tells it when the bot is
    /// stuck on a person, and (optionally) lets paired chats know a routine finished.
    func telegramAfterRun(botId: String, threadKey: String, silent: Bool = false) {
        guard appConfig.telegram.enabled, telegramToken != nil, !silent else { return }
        guard let thread = threads[threadKey], let run = thread.run else { return }
        let botName = bots.first(where: { $0.id == botId })?.name ?? "Bot"
        let lastReply = thread.messages.last(where: { $0.role == .bot && $0.runId == run.id })?.firstText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let chatId = telegramReplyTargets[botId] {
            switch run.status {
            case .running, .queued, .leased:
                return
            case .waitingInput:
                if let pending = thread.pendingTool {
                    telegramSend(chatId, "\(botName) wants to use \(pending.tool): \(pending.detail)\n\nReply /approve or /deny.")
                } else if !lastReply.isEmpty {
                    telegramSend(chatId, lastReply)
                }
            case .waitingTakeover:
                telegramSend(chatId, "\(botName) needs you at the computer to continue (a login or captcha).")
            case .completed:
                telegramReplyTargets.removeValue(forKey: botId)
                telegramSend(chatId, lastReply.isEmpty ? "Done." : lastReply)
            case .failed:
                telegramReplyTargets.removeValue(forKey: botId)
                telegramSend(chatId, "⚠️ " + (lastReply.isEmpty ? (run.error ?? "That didn't work.") : lastReply))
            case .cancelled:
                telegramReplyTargets.removeValue(forKey: botId)
            }
            return
        }

        // Not a chat reply: a routine finishing is worth a short note.
        guard appConfig.telegram.notifyRoutines, run.status == .completed,
              let routine = routineForRun(run), routine.notify, !lastReply.isEmpty
        else { return }
        let note = "⏰ \(routine.name) (\(botName))\n\n" + String(lastReply.prefix(1_500))
        for chatId in appConfig.telegram.allowedChatIds {
            telegramSend(chatId, note)
        }
    }
}

extension AppStore {
    /// Swaps the network for a stand-in so tests can watch what would be sent.
    public func setTelegramAPIForTesting(_ api: any TelegramAPI) {
        telegramAPIFactory = { _ in api }
    }
}
