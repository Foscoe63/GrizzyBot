import Foundation

// The Private desktop's controls and live state for the UI. The container work itself is `PodmanDesktop`.
extension AppStore {
    /// Whether this bot's computer resolves to a Private desktop.
    public func isPrivateDesktop(botId: String) -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        return resolvedComputerMode(for: bot) == .privateDesktop
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
