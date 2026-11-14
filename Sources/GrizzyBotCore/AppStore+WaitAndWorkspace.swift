import Foundation
import Observation

// Test/automation waiting helpers, secrets, workspace import/backup, and sidebar helpers.
extension AppStore {
    public func waitForPluginTasks() async {
        let tasks = Array(pluginTasks.values)
        for task in tasks {
            _ = await task.result
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Wait for a condition, counting scheduling opportunities rather than
    /// elapsed time.
    ///
    /// Wall clock is the wrong clock for these helpers. `AppStore` is
    /// `@MainActor`, the test suites run in parallel against that one actor,
    /// and under contention several seconds can pass before a continuation is
    /// scheduled at all — while the work being awaited is milliseconds (tests
    /// build stores with `delayScale: 0.01`). A wall-clock deadline therefore
    /// failed tests that were not broken, and did so more often the more of
    /// the suite ran alongside them.
    ///
    /// Counting polls scales with load instead: the producer gets the same
    /// number of chances to run on an idle machine and a saturated one.
    /// `timeout` expresses that budget as the time it would take when idle.
    /// The absolute cap exists only so a genuine deadlock still ends the run
    /// rather than hanging the suite.
    func poll(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        if condition() { return true }
        let attempts = max(1, Int((timeout / Self.pollInterval).rounded()))
        let hardDeadline = Date().addingTimeInterval(Self.pollHardCap)
        for _ in 0 ..< attempts {
            try? await Task.sleep(for: .milliseconds(20))
            if condition() { return true }
            if Date() > hardDeadline { break }
        }
        return condition()
    }

    static let pollInterval: TimeInterval = 0.02
    static let pollHardCap: TimeInterval = 240

    /// Await the task owning the thread's current run, following the chain
    /// when one run starts a follow-up (approving a tool continues into a new
    /// run).
    ///
    /// Every run is registered in `runTasks` in the same synchronous step that
    /// publishes it on the thread, and `runAgent` clears its entry before
    /// returning — so a run visible here always has its task, and awaiting
    /// that task means the run's status is final. No polling window to lose.
    func drainRuns(for key: String) async {
        var awaited = Set<String>()
        while let run = threads[key]?.run, run.status.isActive {
            guard let task = runTasks[run.id], awaited.insert(run.id).inserted else { break }
            _ = await task.value
        }
    }

    /// Wait for a peer bot's run to settle on behalf of a waiting `message_bot`.
    ///
    /// Bounded on purpose. `drainRuns` awaits the run's task outright, which is
    /// right for tests but would pin the delegating bot's turn open for as long
    /// as the peer cares to work. Polling the status instead keeps the cap, and
    /// costs nothing in the normal case because `RunStatus.isActive` excludes
    /// `waitingInput` / `waitingTakeover` — a peer that stops for an approval
    /// gate settles here immediately rather than burning the whole budget.
    ///
    /// Counting scheduling opportunities rather than wall clock, for the reason
    /// `poll` documents.
    func awaitPeerReply(threadKey key: String) async -> RunStatus? {
        _ = await poll(timeout: peerReplyTimeout) {
            self.threads[key]?.run?.status.isActive != true
        }
        return threads[key]?.run?.status
    }

    public func waitForRunStatus(botId: String, status: RunStatus, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        return await poll(timeout: timeout) { self.threads[key]?.run?.status == status }
    }

    public func waitForPendingTool(botId: String, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        return await poll(timeout: timeout) { self.threads[key]?.pendingTool != nil }
    }

    public func waitForRunCompletion(botId: String, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        await drainRuns(for: key)
        guard let run = threads[key]?.run else { return true }
        if !run.status.isActive { return run.status == .completed }
        // Still active with no task of its own to await — another path owns it.
        _ = await poll(timeout: timeout) { self.threads[key]?.run?.status.isActive != true }
        return threads[key]?.run?.status == .completed
    }

    public func waitForComputerState(botId: String, state: ComputerState, timeout: TimeInterval = 10) async -> Bool {
        if computers[botId]?.state == state { return true }
        // `boot` publishes its task synchronously, so awaiting it is exact.
        if let task = bootTasks[botId] {
            _ = await task.value
            if computers[botId]?.state == state { return true }
        }
        // Other transitions — `takeControl`, or a run opening the computer
        // surface mid-turn — are not a single awaitable task.
        return await poll(timeout: timeout) { self.computers[botId]?.state == state }
    }

    public func waitForActiveRuns(timeout: TimeInterval = 120) async {
        let attempts = max(1, Int((timeout / Self.pollInterval).rounded()))
        let hardDeadline = Date().addingTimeInterval(Self.pollHardCap)
        for _ in 0 ..< attempts {
            // Awaiting the tracked tasks is the real wait: each returns only
            // after `runAgent` has finalized its run and cleared its entry.
            for task in Array(runTasks.values) {
                _ = await task.result
            }
            if runTasks.isEmpty, routingInFlight.isEmpty, roomRoutingInFlight == 0, dispatchTasks.isEmpty,
               !threads.values.contains(where: { $0.run?.status.isActive == true }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
            if Date() > hardDeadline { return }
        }
    }

    public func appendRunLog(botId: String, kind: String, text: String) {
        runLog = RunLog.appending(runLog, botId: botId, kind: kind, text: text)
    }

    public func lastRunLogText() -> String {
        RunLog.dump(runLog)
    }

    public func clearSecret(_ secret: AppSecret) {
        var config = appConfig
        config.clearSecret(secret)
        saveAppConfig(config)
    }

    public func applySecret(_ secret: AppSecret, input: String) {
        var config = appConfig
        config.applySecret(secret, input: input)
        saveAppConfig(config)
        if secret == .composioConnect || secret == .composioApi {
            Task { await refreshPluginCatalog() }
        }
    }

    @discardableResult
    /// Saves keys from an imported workspace to the Keychain. On failure the import is abandoned,
    /// because the caller would otherwise strip the keys from the workspace and lose them.
    func saveImportedSecrets(_ secrets: WorkspaceSecrets, userId: String) -> Bool {
        do {
            try SecretStore.save(secrets, userId: userId)
            return true
        } catch {
            lastWorkspaceError = "Could not save the imported keys to the Keychain, so nothing was imported (\(error.localizedDescription))."
            appendRunLog(botId: activeBotId ?? "workspace", kind: "import", text: lastWorkspaceError ?? "")
            return false
        }
    }

    public func importWorkspaceJSON(_ data: Data) -> Bool {
        lastWorkspaceError = nil
        guard var ws = try? userPersistence.decodeJSON(UserWorkspace.self, from: data) else { return false }
        if let userId = session?.userId {
            let imported = WorkspaceSecrets.from(workspace: ws)
            if !imported.isEmpty {
                if var existing = SecretStore.load(userId: userId) {
                    if imported.apiKey != nil { existing.apiKey = imported.apiKey }
                    if imported.oauthJSON != nil { existing.oauthJSON = imported.oauthJSON }
                    if !imported.providerCredentials.isEmpty {
                        existing.providerCredentials.merge(imported.providerCredentials) { _, n in n }
                    }
                    if !imported.connectionSecrets.isEmpty {
                        existing.connectionSecrets.merge(imported.connectionSecrets) { _, n in n }
                    }
                    if imported.composioConnectKey != nil { existing.composioConnectKey = imported.composioConnectKey }
                    if imported.composioApiKey != nil { existing.composioApiKey = imported.composioApiKey }
                    if imported.googleClientId != nil { existing.googleClientId = imported.googleClientId }
                    if imported.googleClientSecret != nil { existing.googleClientSecret = imported.googleClientSecret }
                    if imported.boxToken != nil { existing.boxToken = imported.boxToken }
                    if imported.ttsKey != nil { existing.ttsKey = imported.ttsKey }
                    if imported.sentryDSN != nil { existing.sentryDSN = imported.sentryDSN }
                    if imported.braveSearchKey != nil { existing.braveSearchKey = imported.braveSearchKey }
                    if !saveImportedSecrets(existing, userId: userId) { return false }
                } else {
                    if !saveImportedSecrets(imported, userId: userId) { return false }
                }
                ws = imported.stripped(from: ws)
            } else if let existing = SecretStore.load(userId: userId) {
                ws = existing.applying(to: ws)
            }
        }
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(ws)
        route = bots.isEmpty ? .onboarding : .shell
        save()
        return true
    }

    @discardableResult
    public func writeWorkspaceBackup(to directory: URL? = nil) -> URL? {
        lastWorkspaceError = nil
        guard let data = exportWorkspaceJSON() else { return nil }
        let dir = directory ?? WorkspaceBackup.backupDirectory()
        let url = dir.appendingPathComponent(WorkspaceBackup.filename())
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            appendRunLog(botId: activeBotId ?? "workspace", kind: "backup", text: url.path)
            return url
        } catch {
            lastWorkspaceError = "Could not write the backup: \(error.localizedDescription)"
            appendRunLog(botId: activeBotId ?? "workspace", kind: "backup", text: lastWorkspaceError ?? "")
            return nil
        }
    }

    public func diagnosticsDirectory() -> URL {
        userPersistence.diagnosticsDirectory
    }

    public func deleteGroup(_ groupId: String) {
        groups.removeAll { $0.id == groupId }
        threads.removeValue(forKey: groupId)
        if activeGroupId == groupId {
            activeGroupId = nil
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public var allRoutines: [Routine] {
        routines.values.flatMap { $0 }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    public func setRoutineActive(_ routineId: String, active: Bool) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?[idx].active = active
            if active, let routine = routines[botId]?[idx], routine.hasSchedule {
                // A routine switched back on must not wake up to a "next run" from before it was paused.
                routines[botId]?[idx].nextRunAt = Cron.nextDate(routine.cron, from: .now, timezone: routine.timezone)
            }
            save()
            return
        }
    }

    public func setDraft(threadKey: String, text: String) {
        composerDrafts[threadKey] = text
    }

    public func draft(for threadKey: String) -> String {
        composerDrafts[threadKey] ?? ""
    }

    public func selectBotByIndex(_ index: Int) {
        let list = visibleBots
        guard list.indices.contains(index) else { return }
        selectBot(list[index].id)
    }

    public func selectAdjacentBot(delta: Int) {
        let list = visibleBots
        guard !list.isEmpty else { return }
        let current = list.firstIndex(where: { $0.id == activeBotId }) ?? 0
        let next = (current + delta + list.count) % list.count
        selectBot(list[next].id)
    }

    public var missedRoutineCount: Int {
        routines.values.flatMap { $0 }.filter { routine in
            guard let next = routine.nextRunAt else { return false }
            return routine.active && next < Date.now.addingTimeInterval(-12 * 3600)
        }.count
    }
}
