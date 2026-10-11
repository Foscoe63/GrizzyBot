import Foundation

// Event triggers for routines: webhooks and heartbeats.
extension AppStore {
    // MARK: - Webhooks

    static func webhookSecretKey(_ routineId: String) -> String { "webhook:\(routineId)" }

    /// Where an outside system should POST to fire this routine.
    public func webhookURL(routineId: String) -> String {
        "http://127.0.0.1:\(appConfig.webhookPort)/hooks/\(routineId)"
    }

    /// Turns the webhook on and returns the secret. This is the only time the secret is shown.
    @discardableResult
    public func enableWebhook(routineId: String) -> String? {
        guard let (botId, idx) = routineLocation(routineId) else { return nil }
        let secret = WebhookSecret.generate()
        connectionSecrets[Self.webhookSecretKey(routineId)] = secret
        routines[botId]?[idx].webhookEnabled = true
        save()
        return secret
    }

    /// Replaces the secret; the old one stops working at once.
    @discardableResult
    public func rotateWebhookSecret(routineId: String) -> String? {
        guard let (botId, idx) = routineLocation(routineId), routines[botId]?[idx].webhookEnabled == true else { return nil }
        let secret = WebhookSecret.generate()
        connectionSecrets[Self.webhookSecretKey(routineId)] = secret
        save()
        return secret
    }

    public func disableWebhook(routineId: String) {
        guard let (botId, idx) = routineLocation(routineId) else { return }
        routines[botId]?[idx].webhookEnabled = false
        connectionSecrets.removeValue(forKey: Self.webhookSecretKey(routineId))
        save()
    }

    func routineLocation(_ routineId: String) -> (String, Int)? {
        for (botId, list) in routines {
            if let idx = list.firstIndex(where: { $0.id == routineId }) { return (botId, idx) }
        }
        return nil
    }

    /// What the receiver does with a request once it has been parsed. Never reveals whether a
    /// routine exists to a caller without its secret.
    public func handleWebhook(routineId: String, secret: String?, payload: String?) -> WebhookReceiver.Outcome {
        let unauthorized = WebhookReceiver.Outcome(status: 401, message: "unauthorized")
        guard let (botId, idx) = routineLocation(routineId),
              let routine = routines[botId]?[idx],
              routine.webhookEnabled,
              let expected = connectionSecrets[Self.webhookSecretKey(routineId)],
              let secret, WebhookSecret.matches(secret, expected)
        else { return unauthorized }
        guard routine.active else { return WebhookReceiver.Outcome(status: 409, message: "routine is paused") }

        // A slow routine must not build a queue behind a chatty sender.
        let now = Date.now
        if let last = webhookLastFire[routineId], now.timeIntervalSince(last) < 2 {
            return WebhookReceiver.Outcome(status: 429, message: "slow down")
        }
        let key = threadKey(for: botId)
        if routine.inProgress || threads[key]?.run?.status == .running {
            return WebhookReceiver.Outcome(status: 409, message: "busy — the previous run is still going")
        }
        webhookLastFire[routineId] = now
        fireRoutine(botId: botId, routine: routine, webhookPayload: payload, viaWebhook: true)
        recordAudit(
            type: .routineWebhook, botId: botId, tool: routine.name,
            reason: "webhook fired \(routine.name)", allowed: true, forwarded: true
        )
        return WebhookReceiver.Outcome(status: 202, message: "started")
    }

    func syncWebhookReceiver() async {
        guard appConfig.webhooksEnabled, delayScale >= 1, !headlessRoutineTick else {
            await webhookReceiver.stop()
            return
        }
        let port = appConfig.webhookPort
        if await webhookReceiver.isRunning, await webhookReceiver.port == port { return }
        try? await webhookReceiver.start(port: port) { [weak self] routineId, secret, payload in
            guard let self else { return WebhookReceiver.Outcome(status: 503, message: "app closed") }
            return await MainActor.run {
                self.handleWebhook(routineId: routineId, secret: secret, payload: payload)
            }
        }
    }

    // MARK: - Heartbeat

    /// A standing check-in. `everyMinutes` of 60 or more is rounded to whole hours.
    @discardableResult
    public func createHeartbeat(botId: String, name: String = "Heartbeat", checklist: String, everyMinutes: Int = 30) -> Routine? {
        guard bots.contains(where: { $0.id == botId }) else { return nil }
        let cron = Self.heartbeatCron(everyMinutes: everyMinutes)
        let routine = Routine(
            id: Ids.new(),
            botId: botId,
            name: name,
            prompt: checklist,
            cron: cron,
            notify: true,
            nextRunAt: Cron.nextDate(cron, from: .now),
            heartbeat: true,
            continuity: true
        )
        routines[botId, default: []].append(routine)
        save()
        return routine
    }

    public static func heartbeatCron(everyMinutes: Int) -> String {
        let minutes = max(5, everyMinutes)
        if minutes < 60 { return "*/\(minutes) * * * *" }
        let hours = min(24, max(1, minutes / 60))
        return hours >= 24 ? "0 9 * * *" : "0 */\(hours) * * *"
    }

    /// Routine settings that are not part of the schedule form.
    public func setRoutineOptions(_ routineId: String, continuity: Bool? = nil, heartbeat: Bool? = nil) {
        guard let (botId, idx) = routineLocation(routineId) else { return }
        if let continuity { routines[botId]?[idx].continuity = continuity }
        if let heartbeat { routines[botId]?[idx].heartbeat = heartbeat }
        save()
    }
}
