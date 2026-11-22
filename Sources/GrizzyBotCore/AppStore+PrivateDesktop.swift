import Foundation

// The Private desktop's controls and live state for the UI. The container work itself is `PodmanDesktop`.
extension AppStore {
    /// Whether this bot's computer resolves to a Private desktop.
    public func isPrivateDesktop(botId: String) -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        return resolvedComputerMode(for: bot) == .privateDesktop
    }

    /// What a bot is told when it asks a person to take over a desktop the person cannot drive.
    static let privateDesktopTakeoverRefusal: (output: String, reason: String) = (
        "Refused request_takeover: this is a Private desktop, which a person cannot take over or type into. Do not ask for a sign-in, "
            + "captcha or two-factor code here. Tell the person in your reply what is blocking you and stop; they can switch this bot to "
            + "the In-app browser or This Mac if you need to sign in.",
        "A Private desktop cannot be taken over by a person."
    )

    // MARK: Mac folders

    /// The folders this bot's desktop shows, and the ones left out with the reason. Only folders the bot is also granted.
    public func privateDesktopFolders(botId: String)
        -> (mounts: [PodmanDesktopMount], skipped: [PodmanDesktopMountSkip]) {
        guard let bot = bots.first(where: { $0.id == botId }) else { return ([], []) }
        let chosen = grantedFolders(for: bot).filter { bot.desktopFolderIds.contains($0.id) }
        return PodmanDesktopMounts.resolve(chosen, protectedPaths: [globalRoot.path])
    }

    /// Lets the desktop ask this store which folders a bot may show, whenever it makes one.
    func installPrivateDesktopMounts() {
        guard let privateDesktop else { return }
        Task { [weak self] in
            await privateDesktop.setMountsProvider { botId in
                await MainActor.run { self?.privateDesktopFolders(botId: botId).mounts ?? [] }
            }
        }
    }

    /// Shows (or stops showing) one granted folder inside the bot's Private desktop. A desktop cannot change its mounts,
    /// so a running one is removed and the next use makes a new one; the bot's workspace folder is kept.
    public func setDesktopFolder(botId: String, folderId: String, shown: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }),
              let folder = grantedFolders.first(where: { $0.id == folderId }) else { return }
        let was = bots[idx].desktopFolderIds.contains(folderId)
        guard shown != was else { return }
        // A folder can only be shown if the bot is granted it, and a refused one is not turned on at all.
        if shown {
            guard bots[idx].grantedFolderIds.contains(folderId), desktopFolderRefusal(folder) == nil else { return }
        }
        bots[idx].desktopFolderIds.removeAll { $0 == folderId }
        if shown { bots[idx].desktopFolderIds.append(folderId) }
        bots[idx].updatedAt = .now
        save()
        recordAudit(
            type: .configurationChanged, botId: botId, tool: "private_desktop_folder",
            reason: shown ? "Showed \(folder.name) in the Private desktop, read-only." : "Stopped showing \(folder.name) in the Private desktop.",
            allowed: true, forwarded: false
        )
        if bots[idx].computerMode == .privateDesktop, privateDesktopStates[botId]?.status?.container != .missing {
            resetPrivateDesktop(botId: botId)
        }
    }

    /// Why a granted folder cannot be shown in a desktop, or nil when it can.
    public func desktopFolderRefusal(_ folder: GrantedFolder) -> String? {
        PodmanDesktopMounts.refusal(for: folder.path, home: PodmanDesktopMounts.canonical(NSHomeDirectory()),
                                    protectedPaths: [PodmanDesktopMounts.canonical(globalRoot.path)],
                                    visibleRoots: ["/Users", "/Volumes"])
    }

    /// Takes a folder out of every desktop when it is no longer granted to the bot, or removed.
    func pruneDesktopFolders() {
        let granted = Set(grantedFolders.map(\.id))
        for idx in bots.indices {
            let kept = bots[idx].desktopFolderIds.filter { granted.contains($0) && bots[idx].grantedFolderIds.contains($0) }
            guard kept != bots[idx].desktopFolderIds else { continue }
            bots[idx].desktopFolderIds = kept
            if bots[idx].computerMode == .privateDesktop { resetPrivateDesktop(botId: bots[idx].id) }
        }
    }

    public func privateDesktopState(botId: String) -> PrivateDesktopBotState {
        privateDesktopStates[botId] ?? PrivateDesktopBotState()
    }

    private func updatePrivateDesktop(_ botId: String, _ change: (inout PrivateDesktopBotState) -> Void) {
        var state = privateDesktopStates[botId] ?? PrivateDesktopBotState()
        change(&state)
        privateDesktopStates[botId] = state
    }

    /// Podman and the image, for Settings.
    public func refreshPrivateDesktopEnvironment() async {
        guard let privateDesktop else { return }
        privateDesktopEnvironment = await privateDesktop.environment()
    }

    /// One look at a bot's desktop: its status, and a fresh picture of the screen when it is running. Never starts it, so
    /// looking at a panel cannot cost the person a container.
    public func refreshPrivateDesktop(botId: String) async {
        guard let privateDesktop else { return }
        let status = await privateDesktop.status(botId: botId)
        privateDesktopEnvironment = status
        var frame: Data?
        if status.container == .running, status.ready {
            frame = await privateDesktop.screenshot(botId: botId)
        }
        updatePrivateDesktop(botId) {
            $0.status = status
            if status.container == .running { $0.frame = frame ?? $0.frame } else { $0.frame = nil }
        }
    }

    /// Downloads the base (over 1 GB) and builds GrizzyBot's layer. Slow, so it only runs when the person asks.
    public func buildPrivateDesktopImage() {
        guard let privateDesktop, !privateDesktopImageWorking else { return }
        privateDesktopImageWorking = true
        privateDesktopImageError = nil
        Task {
            do { try await privateDesktop.prepareImage() } catch { privateDesktopImageError = error.localizedDescription }
            privateDesktopImageWorking = false
            await refreshPrivateDesktopEnvironment()
        }
    }

    public func startPrivateDesktop(botId: String) {
        runPrivateDesktop(botId, working: "Starting the desktop…") { desktop in
            try await desktop.ensureRunning(botId: botId)
            try await desktop.waitUntilDisplayReady(botId: botId)
        }
    }

    public func stopPrivateDesktop(botId: String) {
        runPrivateDesktop(botId, working: "Stopping the desktop…") { try await $0.stop(botId: botId) }
    }

    /// Removes the container so the next start makes a fresh one. The bot's workspace folder stays.
    public func resetPrivateDesktop(botId: String) {
        runPrivateDesktop(botId, working: "Resetting the desktop…") { try await $0.remove(botId: botId) }
    }

    private func runPrivateDesktop(_ botId: String, working: String, _ work: @escaping @Sendable (PodmanDesktop) async throws -> Void) {
        guard let privateDesktop, privateDesktopState(botId: botId).working == nil else { return }
        updatePrivateDesktop(botId) { $0.working = working; $0.error = nil }
        Task {
            var failure: String?
            do { try await work(privateDesktop) } catch { failure = error.localizedDescription }
            updatePrivateDesktop(botId) { $0.working = nil; $0.error = failure }
            await refreshPrivateDesktop(botId: botId)
        }
    }

    /// Stops the desktop of every bot that no longer works on one, so leaving the mode does not leave a container running.
    /// A bot with no desktop costs one quick inspect.
    func stopUnusedPrivateDesktops() {
        guard let privateDesktop else { return }
        let unused = bots.filter { resolvedComputerMode(for: $0) != .privateDesktop }.map(\.id)
        guard !unused.isEmpty else { return }
        Task {
            for botId in unused { try? await privateDesktop.stop(botId: botId) }
        }
    }
}
