import Foundation

extension AppStore {
    /// Handles a built-in command. Returns the reply to show when the command is answered locally,
    /// or nil when the message should go on to the model (`/plan task`, `/goal text`).
    func handleBuiltin(_ command: BuiltinCommand, argument: String, botId: String) -> String? {
        guard let bot = bots.first(where: { $0.id == botId }) else { return "No such bot." }
        switch command {
        case .context:
            return contextBreakdown(for: bot).render()
        case .compact:
            return compactConversation(botId: botId)
        case .usage:
            return usageSummary(botId: botId)
        case .rollback:
            return rollbackReply(botId: botId, argument: argument)
        case .plan:
            let task = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            return task.isEmpty ? "Usage: `/plan <task>` — I'll write a plan without carrying it out." : nil
        case .goal:
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return nil }
            if text.isEmpty {
                if let goal = bots[idx].goal, !goal.isEmpty { return "Standing goal: \(goal)\n\n`/goal clear` to drop it." }
                return "No standing goal. Set one with `/goal <what you want done>`."
            }
            if BuiltinCommands.isClearGoal(text) {
                bots[idx].goal = nil
                save()
                return "Goal cleared."
            }
            bots[idx].goal = String(text.prefix(1_000))
            save()
            return nil
        }
    }

    func contextBreakdown(for bot: Bot) -> ContextBreakdown {
        let provider = bot.modelProvider ?? modelProvider
        let window = AgentLoopRequest.charBudget(provider: provider)
        let botSkills = enabledSkills(for: bot.id)
        let tools = AgentToolCatalog.chatTools(
            enabledIds: bot.enabledTools,
            mcpServers: mcpServers,
            includeDelegation: true,
            skills: botSkills,
            promotedMcp: Array(mcpPromotedTools.values),
            mcpAdvertised: mcpAdvertisedTools
        )
        let toolChars = (try? JSONEncoder().encode(tools).count) ?? tools.count * 300
        let memoryChars = (memory.first(where: { $0.botId == bot.id && $0.path == "MEMORY.md" })?.content.count ?? 0)
            + sharedMemory.count
        let skillChars = SkillMarkdown.catalogPrompt(from: botSkills, injected: []).count
        let base = AgentLoopRequest(
            endpoint: ModelEndpoint(provider: provider ?? "", model: "", baseURL: "https://localhost", apiKey: ""),
            botName: bot.name,
            prompt: "",
            tools: []
        )
        let systemChars = AgentLoop.systemPrompt(for: base).count
        let history = threads[threadKey(for: bot.id)]?.llmMessages ?? []
        return ContextBreakdown(
            entries: [
                .init(label: "System prompt", chars: systemChars),
                .init(label: "Instructions", chars: bot.instructions.count + (bot.goal?.count ?? 0)),
                .init(label: "Memory", chars: memoryChars),
                .init(label: "Skills", chars: skillChars),
                .init(label: "Tools (\(tools.count))", chars: toolChars),
                .init(label: "Conversation", chars: ContextCompactor.encodedSize(history)),
            ],
            windowChars: window
        )
    }

    private func compactConversation(botId: String) -> String {
        let key = threadKey(for: botId)
        guard var thread = threads[key], !thread.llmMessages.isEmpty else { return "Nothing to compact yet." }
        let before = ContextCompactor.encodedSize(thread.llmMessages)
        let provider = bots.first(where: { $0.id == botId })?.modelProvider ?? modelProvider
        let target = max(8_000, AgentLoopRequest.charBudget(provider: provider) / 4)
        let packed = ContextCompactor.compact(thread.llmMessages, budget: min(target, before * 6 / 10))
        guard packed.compacted else { return "Already compact — about \(ContextBreakdown.tokens(before)) tokens." }
        thread.llmMessages = packed.messages
        threads[key] = thread
        save()
        let after = ContextCompactor.encodedSize(packed.messages)
        return "Compacted the working conversation from about \(ContextBreakdown.tokens(before)) to \(ContextBreakdown.tokens(after)) tokens. The chat on screen is unchanged."
    }

    private func usageSummary(botId: String) -> String {
        let mine = usage.filter { $0.botId == botId }
        guard !mine.isEmpty else { return "No usage recorded for this bot yet." }
        let input = mine.reduce(0) { $0 + $1.inputTokens }
        let output = mine.reduce(0) { $0 + $1.outputTokens }
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        let recent = mine.filter { $0.createdAt >= weekAgo }
        let recentTokens = recent.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        return """
        **Usage** — \(mine.count) runs
        Sent: \(ContextBreakdown.format(input)) tokens · Received: \(ContextBreakdown.format(output)) tokens
        Last 7 days: \(recent.count) runs, \(ContextBreakdown.format(recentTokens)) tokens
        """
    }
}

extension AppStore {
    /// Every user/bot message in this bot's own threads (main chat and tasks). Never a sibling's.
    public func sessionDocs(for botId: String) -> [SessionSearch.Doc] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        var keys: [(key: String, label: String)] = [(botId, "main chat")]
        keys += bot.tasks.map { ($0.id, "task “\($0.title)”") }
        var docs: [SessionSearch.Doc] = []
        for (key, label) in keys {
            for message in threads[key]?.messages ?? [] where message.role == .user || message.role == .bot {
                let text = message.firstText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                docs.append(.init(thread: label, role: message.role, date: message.createdAt, text: text))
            }
        }
        return docs
    }
}

extension AppStore {
    /// Saves how these files look before a file tool changes them. Never blocks the change.
    func checkpoint(botId: String, tool: String, paths: [String]) {
        guard let home = try? botHome.homeURL(botId: botId) else { return }
        let absolute = paths.compactMap { botHome.fileLocation(botId: botId, path: $0) }
        let runId = threads[threadKey(for: botId)]?.run?.id
        CheckpointStore.record(home: home, runId: runId, label: tool, paths: absolute)
    }

    fileprivate func rollbackReply(botId: String, argument: String) -> String {
        guard let home = try? botHome.homeURL(botId: botId) else { return "This bot has no home folder." }
        let arg = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if arg.lowercased() == "list" {
            return CheckpointStore.describe(CheckpointStore.list(home: home))
        }
        guard let result = CheckpointStore.rollback(home: home, id: arg.isEmpty ? nil : arg) else {
            return arg.isEmpty
                ? "Nothing to roll back. " + CheckpointStore.describe([])
                : "No checkpoint matches “\(arg)”.\n\n" + CheckpointStore.describe(CheckpointStore.list(home: home))
        }
        if result.restored.isEmpty { return "That checkpoint had nothing left to restore." }
        refreshFilesMirror(botId: botId)
        let names = result.restored.prefix(6).map { "• " + ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        let more = result.restored.count > 6 ? "\n…and \(result.restored.count - 6) more" : ""
        return "Rolled back \(result.restored.count) file(s):\n\(names)\(more)"
    }
}
