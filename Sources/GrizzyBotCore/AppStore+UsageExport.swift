import Foundation
import Observation

// Computer state, usage records, export and deployment.
extension AppStore {
    // MARK: - Computer

    public func openPanel(_ panel: Panel?) {
        self.panel = panel
        if panel == .computer, let botId = activeBotId {
            autoBootIfNeeded(botId: botId)
        }
    }

    public func toggleComputerPanel() {
        if panel == .computer {
            panel = nil
        } else {
            openPanel(.computer)
        }
    }

    /// Mirrors rakazo `openComputer`: boot if needed, take control, open full-window overlay.
    public func openComputerOverlay() {
        guard let botId = activeBotId, let bot = bots.first(where: { $0.id == botId }) else { return }
        let computer = computers[botId]
        let needsTakeover = computer?.controlHolder != .user
        let needsBoot = computer?.state != .running || computer?.screenAvailable != true
        if needsBoot {
            boot(botId: botId, force: true)
        }
        if needsTakeover {
            takeControl(botId: botId)
        }
        computerOpen = true
        heartbeat(botId: botId)
        Task { @MainActor in
            _ = await prepareComputerSurface(botId: botId, bot: bot)
            await computerRuntime?.prepareForDisplay(botId: botId)
        }
    }

    public func closeComputerOverlay() {
        computerOpen = false
    }

    public func reloadCanvases() {
        canvases = canvasBoard.list()
    }

    // MARK: - Usage / export / deployment

    public func weeklySummary() -> UsageSummary {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = usage.filter { $0.createdAt >= cutoff }
        return UsageSummary(
            inputTokens: recent.reduce(0) { $0 + $1.inputTokens },
            outputTokens: recent.reduce(0) { $0 + $1.outputTokens },
            runs: recent.count
        )
    }

    /// Billed tokens for one bot's chat: last first-call prompt, plus lifetime sent/received.
    public func chatTokenStats(botId: String) -> ChatTokenStats {
        let records = usage.filter { $0.botId == botId }
        let last = records.max(by: { $0.createdAt < $1.createdAt })
        return ChatTokenStats(
            lastPromptTokens: last?.billedPromptTokens ?? 0,
            sentTokens: records.reduce(0) { $0 + $1.inputTokens },
            receivedTokens: records.reduce(0) { $0 + $1.outputTokens }
        )
    }

    /// Zeros composer Prompt / Sent / Recv. Pass a bot id for that bot only; `nil` clears every bot.
    /// Chat messages, memory, and files are left alone. Weekly usage uses the same ledger.
    @discardableResult
    public func resetChatTokens(botId: String? = nil) -> Int {
        let before = usage.count
        if let botId {
            usage.removeAll { $0.botId == botId }
        } else {
            usage.removeAll()
        }
        let removed = before - usage.count
        save()
        return removed
    }

    public func exportManifest(botId: String, redacted: Bool = false) -> ExportManifest? {
        guard let bot = bots.first(where: { $0.id == botId }) else { return nil }
        let mem = memory.filter { $0.botId == botId }.map {
            ExportManifest.MemoryEntry(path: $0.path, content: $0.content)
        }
        let rts = (routines[botId] ?? []).map {
            ExportManifest.RoutineExport(name: $0.name, prompt: $0.prompt, cron: $0.cron, timezone: $0.timezone)
        }
        let fileEntries = files.map { ExportManifest.FileEntry(path: $0[0], content: $0.count > 1 ? $0[1] : "") }
        let history = threads[botId]?.messages ?? []
        let manifest = ExportManifest(
            bot: .init(
                name: bot.name,
                title: bot.title,
                description: bot.description,
                instructions: bot.instructions
            ),
            memory: mem,
            routines: rts,
            files: fileEntries,
            history: history
        )
        return redacted ? manifest.redacted() : manifest
    }

    public func setComputerHost(_ host: String) {
        deployment.computerHost = ComputerHost.normalize(host)?.rawValue ?? ComputerHost.inAppBrowser.rawValue
        showHostPrompt = false
        save()
    }

    public func exportFilename(for botId: String) -> String {
        let name = bots.first(where: { $0.id == botId })?.name ?? "bot"
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(slug)-export.json"
    }
}
