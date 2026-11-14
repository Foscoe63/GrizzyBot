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

    // MARK: - Team check-ins

    /// Check-ins at fixed local times (e.g. "09:00", "16:30") for the lead bot: one heartbeat routine
    /// per time, each skipped while the person is mid-conversation and handed a team snapshot.
    /// Replaces any earlier team check-ins for that bot. An empty `times` just removes them.
    @discardableResult
    public func setTeamCheckins(botId: String, times: [String], timezone: String = "") -> [Routine] {
        guard bots.contains(where: { $0.id == botId }) else { return [] }
        routines[botId, default: []].removeAll { $0.teamCheckin && $0.name != DayWatch.routineName }
        var made: [Routine] = []
        for time in TeamCheckin.normalizedTimes(times) {
            guard let cron = TeamCheckin.cron(forTime: time) else { continue }
            let routine = Routine(
                id: Ids.new(), botId: botId, name: "Check-in \(time)",
                prompt: "Look at what is going on: tasks and approvals waiting on me, what changed, what is next today. "
                    + "Say ONE short thing only if it is genuinely useful.",
                cron: cron, timezone: timezone, notify: true,
                nextRunAt: Cron.nextDate(cron, from: .now, timezone: timezone),
                heartbeat: true, continuity: true
            )
            var r = routine
            r.teamCheckin = true
            routines[botId, default: []].append(r)
            made.append(r)
        }
        save()
        return made
    }

    /// The "HH:mm" times of this bot's team check-ins, earliest first.
    public func teamCheckinTimes(botId: String) -> [String] {
        let times = (routines[botId] ?? []).filter { $0.teamCheckin && $0.name != DayWatch.routineName }.compactMap { r -> String? in
            let f = r.cron.split(separator: " ")
            guard f.count == 5, let m = Int(f[0]), let h = Int(f[1]) else { return nil }
            return String(format: "%02d:%02d", h, m)
        }
        return times.sorted()
    }

    // MARK: - Day watch

    public func isDayWatchOn(botId: String) -> Bool {
        (routines[botId] ?? []).contains { $0.name == DayWatch.routineName && $0.teamCheckin }
    }

    /// Turns the "Keep an eye on my day" routine on or off for the lead bot.
    @discardableResult
    public func setDayWatch(botId: String, enabled: Bool, timezone: String = "") -> Routine? {
        guard bots.contains(where: { $0.id == botId }) else { return nil }
        routines[botId, default: []].removeAll { $0.name == DayWatch.routineName && $0.teamCheckin }
        guard enabled else { save(); return nil }
        var r = Routine(
            id: Ids.new(), botId: botId, name: DayWatch.routineName, prompt: DayWatch.prompt,
            cron: DayWatch.cron, timezone: timezone, notify: true,
            nextRunAt: Cron.nextDate(DayWatch.cron, from: .now, timezone: timezone),
            heartbeat: true, continuity: true
        )
        r.teamCheckin = true
        routines[botId, default: []].append(r)
        save()
        return r
    }

    func lastPersonMessageDate() -> Date? {
        threads.values.flatMap(\.messages).filter { $0.role == .user }.map(\.createdAt).max()
    }

    func teamSnapshot() -> TeamCheckin.Snapshot {
        let names = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0.name) })
        let approvals = bots.compactMap { bot -> String? in
            pendingApprovalMessageId(botId: bot.id) == nil ? nil : "\(bot.name) is waiting on an approval"
        }
        let since = Date.now.addingTimeInterval(-Double(TeamCheckin.routineWindowHours) * 3600)
        let recent = routines.flatMap { botId, list in
            list.filter { !$0.teamCheckin && ($0.lastRunAt ?? .distantPast) > since }
                .map { "\($0.name) (\(names[botId] ?? botId))" }
        }
        let team = bots.filter { !$0.chiefOfStaff }.map(\.name)
        let failing = routines.flatMap { botId, list in
            list.filter { !$0.teamCheckin && $0.failCount > 0 }
                .map { "\($0.name) (\(names[botId] ?? botId))" + ($0.lastError.map { ": \($0.prefix(80))" } ?? "") }
        }
        var snap = TeamCheckin.Snapshot(pendingApprovals: approvals, recentRoutines: recent.sorted(), team: team)
        snap.failedRoutines = failing.sorted()
        return snap
    }
}
