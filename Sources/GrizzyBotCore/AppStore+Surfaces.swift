import Foundation
import Observation

// Split out of Store.swift by its MARK sections; behavior is unchanged.
extension AppStore {
    // MARK: - OpenMausBot-inspired surfaces

    public var visibleBots: [Bot] {
        bots.filter { !$0.hidden }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    public func openAppSettings(section: AppSettingsSection = .general) {
        appSettingsSection = section
        appSettingsOpen = true
    }

    /// Empty workspaces land on onboarding. UI tests need the shell overlays.
    public func prepareUITestWorkspace() {
        if bots.isEmpty {
            _ = createBot(name: "UI Test")
        }
        route = .shell
        showHostPrompt = false
        modelSettingsOpen = false
        pluginsOpen = false
        skillsOpen = false
        appSettingsOpen = false
        computerOpen = false
        canvasOpen = false
    }

    public func closeAppSettings() {
        appSettingsOpen = false
    }

    public func saveAppConfig(_ config: AppConfig) {
        appConfig = config
        if var session {
            if !config.profileName.isEmpty { session.name = config.profileName }
            if !config.profileEmail.isEmpty { session.email = config.profileEmail }
            self.session = session
        }
        applyBoxToken(config.boxToken, persist: false)
        save()
        refreshLocalIntegrations()
    }

    /// Restart folder watchers + local OpenAI/MCP gateway from current config.
    public func refreshLocalIntegrations() {
        Task { await self.syncFolderWatchers() }
        Task { await self.syncLocalGateway() }
        Task { await self.syncWebhookReceiver() }
        Task { await self.syncTelegram() }
    }

    public func reloadFolderWatchers() {
        folderWatchers = (try? FolderWatcherPersistence.loadAll(root: userPersistence.root)) ?? []
    }

    public func saveFolderWatcher(_ watcher: FolderWatcherRecord) throws {
        var record = watcher
        record.watchPath = (record.watchPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.watchPath.isEmpty else {
            throw FolderWatcherError.emptyPath
        }
        try FolderWatcherPersistence.save(record, root: userPersistence.root)
        reloadFolderWatchers()
        refreshLocalIntegrations()
    }

    public func deleteFolderWatcher(id: String) throws {
        folderWatcherService.suppression.release(id)
        try FolderWatcherPersistence.delete(id: id, root: userPersistence.root)
        reloadFolderWatchers()
        refreshLocalIntegrations()
    }

    /// Sends the watcher prompt to its bot immediately (does not wait for FSEvents).
    @discardableResult
    public func runFolderWatcherNow(id: String) -> String {
        guard let watcher = folderWatchers.first(where: { $0.id == id }) else {
            return FolderWatcherError.notFound.localizedDescription
        }
        let result = fireFolderWatcher(watcher, changedPaths: [], manual: true)
        var updated = watcher
        if result.hasPrefix("No bot") {
            updated.lastError = result
        } else if result.hasPrefix("Triggered") {
            updated.lastTriggeredAt = FolderWatcherRecord.isoNow()
            updated.lastError = nil
            if let botId = updated.botId ?? activeBotId ?? bots.first?.id {
                selectBot(botId)
            }
        }
        try? FolderWatcherPersistence.save(updated, root: userPersistence.root)
        reloadFolderWatchers()
        return result
    }

    public func discoverMcpBonjour(timeoutSeconds: TimeInterval = 5) async -> [MCPBonjourDiscovery.Entry] {
        await MCPBonjourDiscovery.discover(timeoutSeconds: timeoutSeconds)
    }

    public func memoryDedupeClusters(botId: String) -> [MemoryFactCluster] {
        let content = memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
        return MemoryFactDedupe.clusters(from: MemoryLedger.parse(content).facts)
    }

    @discardableResult
    public func mergeMemoryDuplicates(botId: String) -> [String] {
        guard let idx = memory.firstIndex(where: { $0.botId == botId && $0.path == "MEMORY.md" }) else {
            return []
        }
        let result = MemoryFactDedupe.mergeContent(memory[idx].content)
        memory[idx].content = result.text
        memory[idx].updatedAt = .now
        save()
        return result.removed
    }

    private func syncFolderWatchers() async {
        let root = userPersistence.root
        let runner = StoreFolderWatcherRunner { [weak self] watcher, paths, manual in
            guard let self else { return "store released" }
            return await MainActor.run {
                self.fireFolderWatcher(watcher, changedPaths: paths, manual: manual)
            }
        }
        await folderWatcherService.configure(root: root, runner: runner)
        if appConfig.enableFolderWatchers {
            await folderWatcherService.start()
            await folderWatcherService.reloadNow()
        } else {
            await folderWatcherService.stop()
        }
    }

    /// Test/UI seam: apply an automatic FSEvent-style fire (honors busy + cooldown skips).
    @discardableResult
    public func handleFolderWatcherEvent(id: String, changedPaths: [String]) -> String {
        guard let watcher = folderWatchers.first(where: { $0.id == id }) else {
            return FolderWatcherError.notFound.localizedDescription
        }
        return fireFolderWatcher(watcher, changedPaths: changedPaths, manual: false)
    }

    private func fireFolderWatcher(
        _ watcher: FolderWatcherRecord,
        changedPaths: [String],
        manual: Bool
    ) -> String {
        let botId = watcher.botId ?? activeBotId ?? bots.first?.id
        guard let botId else { return "No bot configured for watcher." }
        if let skip = FolderWatcherFirePolicy.skipReason(
            botBusy: isRunActive(botId: botId),
            suppressed: folderWatcherService.suppression.isSuppressed(watcher.id),
            manual: manual
        ) {
            return skip
        }
        folderWatcherService.suppression.suppress(watcher.id)
        watcherRunByBotId[botId] = watcher.id
        Task { await folderWatcherService.dropPending(watcherId: watcher.id) }
        let prompt = FolderWatcherPromptBuilder.userMessage(
            watcher: watcher,
            changedPaths: changedPaths,
            manual: manual
        )
        let watchPath = (watcher.watchPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        send(
            botId: botId,
            text: prompt,
            workingFolderOverride: watchPath.isEmpty ? nil : watchPath
        )
        return "Triggered bot \(botId)"
    }

    private func watcherEchoCooldown(for watcherId: String) -> TimeInterval {
        let responsiveness = folderWatchers.first(where: { $0.id == watcherId })?.responsiveness ?? "balanced"
        return FolderWatcherGlobMatching.debounceSeconds(for: responsiveness)
    }

    func releaseWorkingFolderOverrideIfNeeded(botId: String) {
        let status = threads[threadKey(for: botId)]?.run?.status
        switch status {
        case .waitingInput, .waitingTakeover, .queued, .leased, .running:
            return
        default:
            runWorkingFolderOverride.removeValue(forKey: botId)
            releaseWatcherSuppressionIfNeeded(botId: botId)
        }
    }

    private func releaseWatcherSuppressionIfNeeded(botId: String) {
        guard let watcherId = watcherRunByBotId.removeValue(forKey: botId) else { return }
        let cooldown = watcherEchoCooldown(for: watcherId)
        Task {
            try? await Task.sleep(for: .seconds(cooldown))
            folderWatcherService.suppression.release(watcherId)
            await folderWatcherService.dropPending(watcherId: watcherId)
        }
    }

    private func syncLocalGateway() async {
        let settings = appConfig.localGateway
        let botPairs = bots.map { (id: $0.id, name: $0.name) }
        await LocalOpenAIGateway.shared.configure(
            settings: settings,
            bots: botPairs,
            handler: { [weak self] botId, messages, _ in
                guard let self else { throw PrivacyFilterBlockedError.criticalPII([.apiKey]) }
                return try await MainActor.run {
                    try self.handleLocalGatewayChat(botId: botId, messages: messages)
                }
            }
        )
        await LocalOpenAIGateway.shared.restart()
    }

    private func handleLocalGatewayChat(botId: String?, messages: [[String: String]]) throws -> String {
        let target = botId ?? appConfig.localGateway.defaultBotId ?? activeBotId ?? bots.first?.id
        guard let target else {
            throw NSError(
                domain: "GrizzyBot",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No bot available"]
            )
        }
        let prompt = messages.reversed().first(where: { $0["role"] == "user" })?["content"]
            ?? messages.last?["content"]
            ?? ""
        let scrubbed = try PrivacyFilter.applyForSend(
            prompt,
            settings: appConfig.privacyFilter,
            logDirectory: userPersistence.root,
            logContext: "local_gateway"
        )
        send(botId: target, text: scrubbed)
        return "Queued on bot \(target). Open GrizzyBot to follow the run."
    }

    func applyBoxToken(_ token: String?, persist: Bool) {
        mergeCatalog(ConnectionCatalog.defaults)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if connectionSecrets["box"] != ComposioClient.composioTokenSentinel {
                connectionSecrets.removeValue(forKey: "box")
            }
            if let idx = connections.firstIndex(where: { $0.slug == "box" }),
               connections[idx].viaComposio == false {
                connections[idx].connected = false
                connections[idx].accountLabel = nil
            }
            if persist { save() }
            return
        }
        if connectionSecrets["box"] != ComposioClient.composioTokenSentinel {
            connectionSecrets["box"] = trimmed
        }
        if let idx = connections.firstIndex(where: { $0.slug == "box" }),
           connections[idx].viaComposio == false {
            connections[idx].connected = true
            connections[idx].accountLabel = connections[idx].accountLabel ?? "Box token"
        }
        if persist { save() }
    }

    public func showRoutinesPage() {
        mainView = .routines
        panel = nil
        activeGroupId = nil
    }

    public func showChat() {
        mainView = .chat
    }

    public func selectGroup(_ groupId: String) {
        activeGroupId = groupId
        activeBotId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        canvasOpen = false
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].unread = false
            save()
        }
    }

    public func selectBot(_ botId: String) {
        activeBotId = botId
        activeGroupId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        canvasOpen = false
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].unread = false
            save()
        }
    }

    @discardableResult
    public func duplicateBot(_ botId: String) -> Bot? {
        guard let source = bots.first(where: { $0.id == botId }) else { return nil }
        let copy = createBot(
            name: "\(source.name) copy",
            title: source.title,
            description: source.description,
            instructions: source.instructions,
            parentBotId: source.parentBotId
        )
        if let idx = bots.firstIndex(where: { $0.id == copy.id }) {
            bots[idx].autoApprove = source.autoApprove
            bots[idx].shellNetwork = source.shellNetwork
            bots[idx].speakReplies = source.speakReplies
            bots[idx].notifications = source.notifications
            bots[idx].computerMode = source.computerMode
            bots[idx].modelProvider = source.modelProvider
            bots[idx].modelId = source.modelId
            bots[idx].enabledTools = source.enabledTools
            save()
            return bots[idx]
        }
        return copy
    }

    public func setBotTool(_ botId: String, toolId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setTool(toolId, enabled: enabled)
        bots[idx].updatedAt = .now
        save()
    }

    public func setAllBotTools(_ botId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setAllTools(enabled: enabled, knownIds: knownToolIds)
        bots[idx].updatedAt = .now
        save()
    }

    public func setDefaultTool(_ toolId: String, enabled: Bool) {
        setDefaultTools([toolId], enabled: enabled)
    }

    public func setDefaultTools(_ toolIds: [String], enabled: Bool) {
        var config = appConfig
        for toolId in toolIds {
            if !config.seenToolIds.contains(toolId) {
                config.seenToolIds.append(toolId)
            }
            if enabled {
                if !config.defaultEnabledTools.contains(toolId) {
                    config.defaultEnabledTools.append(toolId)
                }
            } else {
                config.defaultEnabledTools.removeAll { $0 == toolId }
            }
        }
        appConfig = config
        save()
    }

    public func setAllDefaultTools(enabled: Bool) {
        var config = appConfig
        let ids = knownToolIds
        for id in ids where !config.seenToolIds.contains(id) {
            config.seenToolIds.append(id)
        }
        config.defaultEnabledTools = enabled ? ids : []
        appConfig = config
        save()
    }

    public var knownToolIds: [String] {
        var ids = AgentToolCatalog.allIds(custom: customTools, mcpServers: mcpServers)
        for server in mcpServers {
            ids.append(contentsOf: McpToolGate.childIds(serverId: server.id, names: mcpToolNames(for: server.id)))
        }
        return ids
    }

    public var knownToolDefinitions: [AgentToolDefinition] {
        AgentToolCatalog.definitions(custom: customTools, mcpServers: mcpServers)
    }

    public func mcpStatus(for serverId: String) -> McpProbeStatus {
        if let live = mcpProbeStatus[serverId] { return live }
        if let names = mcpAdvertisedTools[serverId] {
            return .connected(toolCount: names.count)
        }
        return .idle
    }

    public func mcpToolNames(for serverId: String) -> [String] {
        var names = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[serverId] ?? [])
        var seen = Set(names)
        let server = mcpServers.first(where: { $0.id == serverId })
        for promo in mcpPromotedTools.values where promo.serverId == serverId {
            if McpCatalogPromote.isDispatcher(promo.chatName) { continue }
            if let server, promo.chatName == McpNativeNaming.chatName(server: server, tool: promo.executeTool),
               seen.contains(promo.executeTool) {
                continue
            }
            if seen.insert(promo.chatName).inserted {
                names.append(promo.chatName)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func mcpToolDescription(serverId: String, toolName: String) -> String {
        if let info = mcpListedTools[serverId]?.first(where: { $0.name == toolName }),
           !info.description.isEmpty {
            return info.description
        }
        if let promo = mcpPromotedTools.values.first(where: {
            $0.serverId == serverId && $0.chatName == toolName
        }), !promo.description.isEmpty {
            return promo.description
        }
        return "MCP tool"
    }

    public func isDefaultMcpToolEnabled(serverId: String, toolName: String) -> Bool {
        McpToolGate.isToolEnabled(
            enabledIds: appConfig.defaultEnabledTools,
            serverId: serverId,
            toolName: toolName,
            advertised: mcpToolNames(for: serverId)
        )
    }

    public func isBotMcpToolEnabled(botId: String, serverId: String, toolName: String) -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        return McpToolGate.isToolEnabled(
            enabledIds: bot.enabledTools,
            serverId: serverId,
            toolName: toolName,
            advertised: mcpToolNames(for: serverId)
        )
    }

    public func setDefaultMcpChildTool(serverId: String, toolName: String, enabled: Bool) {
        var config = appConfig
        let advertised = mcpToolNames(for: serverId)
        McpToolGate.setChild(
            enabledIds: &config.defaultEnabledTools,
            serverId: serverId,
            toolName: toolName,
            enabled: enabled,
            advertised: advertised
        )
        let parent = "mcp:\(serverId)"
        for id in [parent] + McpToolGate.childIds(serverId: serverId, names: advertised) {
            if !config.seenToolIds.contains(id) {
                config.seenToolIds.append(id)
            }
        }
        appConfig = config
        save()
    }

    public func setBotMcpChildTool(botId: String, serverId: String, toolName: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        var tools = bots[idx].enabledTools
        McpToolGate.setChild(
            enabledIds: &tools,
            serverId: serverId,
            toolName: toolName,
            enabled: enabled,
            advertised: mcpToolNames(for: serverId)
        )
        bots[idx].enabledTools = tools
        bots[idx].updatedAt = .now
        save()
    }

    public func areAllMcpToolsEnabled(scope enabledIds: [String], serverId: String) -> Bool {
        McpToolGate.allChildrenEnabled(
            enabledIds: enabledIds,
            serverId: serverId,
            advertised: mcpToolNames(for: serverId)
        )
    }

    public func setAllDefaultMcpTools(serverId: String, enabled: Bool) {
        var config = appConfig
        let advertised = mcpToolNames(for: serverId)
        McpToolGate.setAllChildren(
            enabledIds: &config.defaultEnabledTools,
            serverId: serverId,
            enabled: enabled,
            advertised: advertised
        )
        for id in ["mcp:\(serverId)"] + McpToolGate.childIds(serverId: serverId, names: advertised)
        where !config.seenToolIds.contains(id) {
            config.seenToolIds.append(id)
        }
        appConfig = config
        save()
    }

    public func setAllBotMcpTools(botId: String, serverId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        var tools = bots[idx].enabledTools
        McpToolGate.setAllChildren(
            enabledIds: &tools,
            serverId: serverId,
            enabled: enabled,
            advertised: mcpToolNames(for: serverId)
        )
        bots[idx].enabledTools = tools
        bots[idx].updatedAt = .now
        save()
    }

    public func probeMcpServer(_ serverId: String) {
        guard let server = mcpServers.first(where: { $0.id == serverId }) else { return }
        if mcpProbeStatus[serverId] == .checking { return }
        let generation = (mcpProbeGeneration[serverId] ?? 0) + 1
        mcpProbeGeneration[serverId] = generation
        mcpProbeStatus[serverId] = .checking
        Task {
            let outcome: Result<[McpToolInfo], Error>
            do {
                outcome = .success(try await McpClient.listTools(server: server))
            } catch {
                outcome = .failure(error)
            }
            guard mcpProbeGeneration[serverId] == generation else { return }
            guard mcpServers.contains(where: { $0.id == serverId }) else { return }
            switch outcome {
            case .success(let listed):
                _ = applyMcpList(serverId: serverId, tools: listed)
            case .failure(let error):
                mcpProbeStatus[serverId] = .failed(error.localizedDescription)
            }
        }
    }

    public func probeAllMcpServers() {
        for server in mcpServers {
            probeMcpServer(server.id)
        }
    }

    @discardableResult
    public func addMcpServer(
        name: String,
        transport: McpTransport,
        command: String,
        args: [String],
        env: [String: String],
        url: String,
        headers: [String: String]
    ) -> McpServer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = McpServer(
            name: trimmed,
            transport: transport,
            command: command,
            args: FastFilesystemMcpArgs.normalize(command: command, args: args),
            env: env,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers
        )
        mcpServers.append(server)
        optInNewTool(server.toolId)
        save()
        return server
    }

    public func updateMcpServer(_ server: McpServer) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        var updated = server
        updated.args = FastFilesystemMcpArgs.normalize(command: updated.command, args: updated.args)
        mcpServers[idx] = updated
        save()
    }

    public func deleteMcpServer(_ serverId: String) {
        mcpServers.removeAll { $0.id == serverId }
        McpToolGate.stripServer(serverId, from: &appConfig.defaultEnabledTools)
        for i in bots.indices {
            McpToolGate.stripServer(serverId, from: &bots[i].enabledTools)
        }
        mcpAdvertisedTools[serverId] = nil
        mcpListedTools[serverId] = nil
        mcpProbeStatus[serverId] = nil
        mcpProbeGeneration[serverId] = nil
        mcpPromotedTools = mcpPromotedTools.filter { $0.value.serverId != serverId }
        save()
    }

    @discardableResult
    func optInNewTool(_ toolId: String) -> Bool {
        if appConfig.seenToolIds.contains(toolId) { return false }
        var config = appConfig
        config.seenToolIds.append(toolId)
        if !config.defaultEnabledTools.isEmpty, !config.defaultEnabledTools.contains(toolId) {
            config.defaultEnabledTools.append(toolId)
        }
        appConfig = config
        for i in bots.indices {
            if !bots[i].enabledTools.contains(toolId), !bots[i].noToolsEnabled {
                bots[i].enabledTools.append(toolId)
            }
        }
        return true
    }

    /// First launch after this field exists: record every known tool so disabled defaults stay off.
    func seedSeenToolIdsIfNeeded() {
        guard appConfig.seenToolIds.isEmpty else { return }
        var seen = Set(AgentToolCatalog.builtinIds)
        seen.formUnion(CanvasBoardStore.toolIds)
        seen.formUnion(ArtifactStore.toolIds)
        seen.formUnion(appConfig.defaultEnabledTools)
        seen.formUnion(customTools.map(\.id))
        seen.formUnion(mcpServers.map(\.toolId))
        for (serverId, names) in mcpAdvertisedTools {
            seen.formUnion(McpToolGate.childIds(serverId: serverId, names: names))
        }
        for bot in bots {
            seen.formUnion(bot.enabledTools)
        }
        var config = appConfig
        config.seenToolIds = Array(seen)
        appConfig = config
        save()
    }

    @discardableResult
    public func addCustomTool(
        name: String,
        description: String,
        triggers: [String],
        responseTemplate: String
    ) -> CustomAgentTool? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let phraseList = triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tool = CustomAgentTool(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            triggers: phraseList.isEmpty ? [trimmed.lowercased()] : phraseList,
            responseTemplate: responseTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ran **{name}** on: {prompt}"
                : responseTemplate
        )
        customTools.append(tool)
        optInNewTool(tool.id)
        save()
        return tool
    }

    public func updateCustomTool(_ tool: CustomAgentTool) {
        guard let idx = customTools.firstIndex(where: { $0.id == tool.id }) else { return }
        customTools[idx] = tool
        save()
    }

    public func deleteCustomTool(_ toolId: String) {
        customTools.removeAll { $0.id == toolId }
        appConfig.defaultEnabledTools.removeAll { $0 == toolId }
        for i in bots.indices {
            bots[i].enabledTools.removeAll { $0 == toolId }
        }
        save()
    }

    public func setBotPinned(_ botId: String, pinned: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].pinned = pinned
        save()
    }

    public func setBotHidden(_ botId: String, hidden: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].hidden = hidden
        if hidden, activeBotId == botId {
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public func markBotUnread(_ botId: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].unread = true
        save()
    }

    public func setChiefOfStaff(_ botId: String, enabled: Bool) {
        for i in bots.indices {
            bots[i].chiefOfStaff = enabled && bots[i].id == botId
        }
        save()
    }

    public func patchBot(
        _ botId: String,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        color: String? = nil,
        autoApprove: Bool? = nil,
        shellNetwork: Bool? = nil,
        speakReplies: Bool? = nil,
        notifications: Bool? = nil,
        computerMode: ComputerMode? = nil,
        modelProvider: String? = nil,
        modelId: String? = nil,
        visibility: BotVisibility? = nil,
        runtime: BotRuntime? = nil,
        aguiURL: String? = nil,
        enabledComponents: [String]? = nil
    ) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let name { bots[idx].name = name }
        if let title { bots[idx].title = title }
        if let description { bots[idx].description = description }
        if let instructions { bots[idx].instructions = instructions }
        if let color { bots[idx].color = color }
        if let autoApprove { bots[idx].autoApprove = autoApprove }
        if let shellNetwork { bots[idx].shellNetwork = shellNetwork }
        if let speakReplies { bots[idx].speakReplies = speakReplies }
        if let notifications { bots[idx].notifications = notifications }
        if let computerMode { bots[idx].computerMode = computerMode }
        if let modelProvider { bots[idx].modelProvider = modelProvider }
        if let modelId { bots[idx].modelId = modelId }
        if let visibility { bots[idx].visibility = visibility }
        if let runtime { bots[idx].runtime = runtime }
        if let aguiURL {
            let trimmed = aguiURL.trimmingCharacters(in: .whitespacesAndNewlines)
            bots[idx].aguiURL = trimmed.isEmpty ? nil : trimmed
        }
        if let enabledComponents { bots[idx].enabledComponents = enabledComponents }
        bots[idx].updatedAt = .now
        save()
    }

    public func setBotModel(_ botId: String, choice: BotModelChoice) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        switch choice {
        case .workspaceDefault:
            bots[idx].modelProvider = nil
            bots[idx].modelId = nil
        case .catalog(let provider, let modelId, _):
            bots[idx].modelProvider = provider
            bots[idx].modelId = modelId
        }
        bots[idx].updatedAt = .now
        save()
    }

    @discardableResult
    public func createGroup(name: String, memberIds: [String]) -> GroupRoom {
        let members = memberIds.isEmpty ? Array(visibleBots.prefix(2).map(\.id)) : memberIds
        let group = GroupRoom(name: name, memberIds: members)
        groups.append(group)
        threads[group.id] = ThreadData(threadId: group.threadId)
        activeGroupId = group.id
        activeBotId = nil
        mainView = .chat
        save()
        return group
    }

    public func updateGroupBulletin(_ groupId: String, bulletin: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].bulletin = bulletin
        save()
    }

    public func sendGroupMessage(groupId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var thread = threads[groupId] else { return }
        guard let gIdx = groups.firstIndex(where: { $0.id == groupId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(trimmed)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        threads[groupId] = thread
        groups[gIdx].preview = trimmed
        save()

        let members = groups[gIdx].memberIds.compactMap { id in bots.first(where: { $0.id == id }) }
        // @mentions pick the responders; without one the room's default applies.
        let queue: [String] = {
            if let mentioned = GroupMentions.responders(for: trimmed, members: members) { return mentioned }
            switch groups[gIdx].defaultResponder {
            case .member(let id):
                return bots.contains(where: { $0.id == id }) ? [id] : []
            case .everyone, .mentions:
                return members.first.map { [$0.id] } ?? []
            }
        }()
        guard !queue.isEmpty else { return }

        let room = groups[gIdx].name
        Task { [weak self] in
            await self?.runGroupTurns(groupId: groupId, roomName: room, members: members, initial: queue, userText: trimmed)
        }
    }

    /// Runs the room's bots one after another. A reply that @mentions another
    /// member pulls that member in next, up to `GroupMentions.maxTurns` turns
    /// per user message, and no bot speaks twice in one chain.
    private func runGroupTurns(
        groupId: String,
        roomName: String,
        members: [Bot],
        initial: [String],
        userText: String
    ) async {
        var queue = initial
        var spoken: Set<String> = []
        var handoffs: [String: (from: String, text: String)] = [:]
        // Plain names, no "@": a bot that echoes this line must not count as mentioning everyone.
        let roster = members.map(\.name).joined(separator: ", ")

        while !queue.isEmpty, spoken.count < GroupMentions.maxTurns {
            let botId = queue.removeFirst()
            guard spoken.insert(botId).inserted,
                  let bot = bots.first(where: { $0.id == botId }),
                  var thread = threads[groupId]
            else { continue }

            let run = Run(id: Ids.new(), botId: botId, threadId: thread.threadId, status: .running, trigger: "group")
            let startSeq = thread.nextSeq
            thread.run = run
            threads[groupId] = thread
            if let idx = bots.firstIndex(where: { $0.id == botId }) { bots[idx].status = "working" }
            save()

            let source = handoffs[botId].map { "\($0.from) said:\n\n\($0.text)" } ?? "The user said:\n\n\(userText)"
            let prompt = """
                [Room "\(roomName)" — members: \(roster) and the user] You are \(bot.name).
                \(source)

                Answer as yourself. To pull a teammate in, write @ followed by their name.
                """
            let runId = run.id
            let inner = Task { [weak self] in
                guard let self else { return }
                await self.runAgent(botId: botId, threadKey: groupId, runId: runId, prompt: prompt)
            }
            runTasks[runId] = inner
            await inner.value

            // Attribute this turn's replies: room threads hold several bots' messages.
            guard var after = threads[groupId] else { return }
            for i in after.messages.indices where after.messages[i].seq >= startSeq
                && after.messages[i].role == .bot && after.messages[i].authorBotId == nil {
                after.messages[i].authorBotId = botId
            }
            threads[groupId] = after
            save()

            guard after.run?.id == runId, after.run?.status == .completed else { break }
            let reply = after.messages.last(where: { $0.role == .bot && $0.seq >= startSeq })?.firstText ?? ""
            let pulled = GroupMentions.parse(reply, members: members).botIds
            for id in pulled where id != botId && !spoken.contains(id) && !queue.contains(id) {
                queue.append(id)
                handoffs[id] = (from: bot.name, text: reply)
            }
        }
    }
}
