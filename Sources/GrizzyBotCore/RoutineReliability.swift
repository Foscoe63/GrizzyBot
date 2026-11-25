import Foundation

/// Small pure rules that keep scheduled work honest when nobody is watching.
public enum RoutineReliability {
    /// How long an approval card on a routine run may wait for a person before the action is skipped.
    public static let approvalExpiry: TimeInterval = 30 * 60
    /// A tick this much later than planned (or less) is on time as far as the bot is concerned.
    public static let latenessThreshold: TimeInterval = 5 * 60
    public static let maxActiveRoutines = 6
    public static let maxPreviewChars = 160
    public static let maxSectionChars = 4_000

    /// "40m", "2h 5m", "1d 3h".
    public static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }

    /// Tells a catch-up run how late it is, so it can say "this morning's report" instead of assuming it is on time.
    /// Missed ticks are never replayed one by one: the schedule moves on from `now`, so there is at most one catch-up run.
    public static func latenessNote(plannedAt: Date?, now: Date = .now) -> String? {
        guard let plannedAt, now.timeIntervalSince(plannedAt) > latenessThreshold else { return nil }
        let late = humanDuration(now.timeIntervalSince(plannedAt))
        return "Started \(late) late (planned for \(plannedAt.formatted(date: .abbreviated, time: .shortened))). Any ticks missed in between were folded into this one run; do not repeat them."
    }

    public static func composeLate(prompt: String, plannedAt: Date?, now: Date = .now) -> String {
        guard let note = latenessNote(plannedAt: plannedAt, now: now) else { return prompt }
        return "\(note)\n\n\(prompt)"
    }

    /// True when an approval card has waited past the limit.
    public static func approvalExpired(askedAt: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(askedAt) >= approvalExpiry
    }

    /// The bot's own standing routines, shown to it as plain information. It is not permission to act on them.
    public static func activeRoutinesSection(_ routines: [Routine], now: Date = .now) -> String? {
        let active = routines.filter(\.active)
        guard !active.isEmpty else { return nil }
        var lines = ["Your standing routines (information only, not a request to run them or permission to act):"]
        var used = lines[0].count
        for routine in active.sorted(by: { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }).prefix(maxActiveRoutines) {
            let preview = routine.prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let clipped = preview.count > maxPreviewChars ? String(preview.prefix(maxPreviewChars)) + "…" : preview
            let when = routine.nextRunAt.map { "next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "on events only"
            let line = "- \(routine.name) (\(routine.hasSchedule ? routine.cron : "events"); \(when)): \(clipped)"
            if used + line.count > maxSectionChars { break }
            lines.append(line)
            used += line.count
        }
        let hidden = active.count - (lines.count - 1)
        if hidden > 0 { lines.append("…and \(hidden) more.") }
        return lines.joined(separator: "\n")
    }
}

extension AppStore {
    /// Skips actions whose approval card sat unanswered on a routine run, so an overnight run does not hang until morning
    /// and block every later tick.
    func expireUnattendedApprovals(now: Date = .now) {
        for (botId, _) in routines {
            let key = threadKey(for: botId)
            guard let thread = threads[key], let run = thread.run, run.status == .waitingInput,
                  RoutineTrigger.isRoutine(run.trigger),
                  let message = thread.messages.last(where: { message in
                      message.blocks.contains { if case .approval(_, _, .pending) = $0 { return true }; return false }
                  }),
                  RoutineReliability.approvalExpired(askedAt: message.createdAt, now: now) else { continue }
            answerApproval(botId: botId, messageId: message.id, decision: .deny)
            appendRunLog(botId: botId, kind: "routine", text: "An approval waited \(RoutineReliability.humanDuration(RoutineReliability.approvalExpiry)) with nobody answering, so the action was skipped")
        }
    }
}
