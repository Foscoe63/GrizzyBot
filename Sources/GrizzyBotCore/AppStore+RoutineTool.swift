import Foundation

// `routine_manage`: a bot makes its own work recur. A routine is standing automation, so creating one
// goes through an approval, and a run that has read outside content needs a person every time —
// otherwise a poisoned page could schedule itself to keep running.
extension AppStore {
    static let maxRoutinesPerBot = 20

    func routineManage(bot: Bot, argumentsJSON: String, approved: Bool, taint: RunTaint?) -> AgentToolCallResult {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        func value(_ key: String) -> String { (args.stringValue(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let action = value("action").lowercased()
        let mine = routines[bot.id] ?? []

        func find() -> Routine? {
            let wanted = [value("id"), value("name")].first { !$0.isEmpty } ?? ""
            guard !wanted.isEmpty else { return nil }
            return mine.first { $0.id == wanted } ?? mine.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        func describe(_ r: Routine) -> String {
            let when = r.hasSchedule ? Cron.formatCron(r.cron) : "events only"
            return "- \(r.name) [\(r.id)] — \(when) — \(r.active ? "on" : "paused")"
        }
        /// The approval a change needs: the person's, always, if outside content has been read.
        func gate(_ detail: String) -> AgentToolCallResult? {
            if approved { return nil }
            if taint?.isTainted == true {
                let sources = taint?.tainters.joined(separator: ", ") ?? "outside content"
                recordAudit(type: .memoryWriteHeld, botId: bot.id, tool: "routine_manage", reason: "routine change after reading \(sources)", allowed: nil, forwarded: false)
                return humanGate(tool: "routine.untrusted", detail: "\(detail) (this run has read \(sources))", argumentsJSON: argumentsJSON)
            }
            return gatedWrite(tool: "routine.change", detail: detail, argumentsJSON: argumentsJSON, bot: bot, approved: false)
        }

        switch action {
        case "list":
            guard !mine.isEmpty else { return AgentToolCallResult(output: "This bot has no routines.") }
            return AgentToolCallResult(
                output: mine.map(describe).joined(separator: "\n"),
                blocks: [.card(lines: mine.prefix(8).map { CardLine(k: $0.name, v: $0.hasSchedule ? Cron.formatCron($0.cron) : "events only") })]
            )

        case "create":
            let name = value("name"), prompt = value("prompt")
            guard !name.isEmpty else { return AgentToolCallResult(output: "name is required") }
            guard !prompt.isEmpty else { return AgentToolCallResult(output: "prompt is required — say what to do on each run, in full.") }
            guard prompt.count <= 4_000 else { return AgentToolCallResult(output: "prompt is too long (4,000 characters at most).") }
            if mine.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return AgentToolCallResult(output: "A routine named “\(name)” already exists. Use action=list to see it, or pick another name.")
            }
            guard mine.count < Self.maxRoutinesPerBot else {
                return AgentToolCallResult(output: "This bot already has \(Self.maxRoutinesPerBot) routines. Delete one first.")
            }
            let schedule: RoutineSchedule.Checked
            do {
                schedule = try RoutineSchedule.resolve(cron: value("cron"), days: value("days"), time: value("time"))
            } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }
            if let gated = gate("Create routine “\(name)” — \(schedule.description) — \(String(prompt.prefix(240)))") { return gated }
            let routine = Routine(
                id: Ids.new(), botId: bot.id, name: name, prompt: prompt, cron: schedule.cron,
                notify: true, nextRunAt: Cron.nextDate(schedule.cron, from: .now)
            )
            routines[bot.id, default: []].append(routine)
            recordAudit(type: .configurationChanged, botId: bot.id, tool: "routine_manage", reason: "created routine “\(name)” (\(schedule.cron))", allowed: true, forwarded: true)
            save()
            return AgentToolCallResult(
                output: "Created routine “\(name)” — \(schedule.description). Next run \(routine.nextRunAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "soon"). It is listed in the Routines page and can be paused there.",
                blocks: [.card(lines: [
                    CardLine(k: "routine", v: name),
                    CardLine(k: "schedule", v: schedule.description),
                    CardLine(k: "cron", v: schedule.cron),
                ])]
            )

        case "pause":
            guard let routine = find() else { return AgentToolCallResult(output: "No routine of yours matches “\(value("id").isEmpty ? value("name") : value("id"))”. Use action=list.") }
            setRoutineActive(routine.id, active: false)
            return AgentToolCallResult(output: "Paused “\(routine.name)”.")

        case "resume":
            guard let routine = find() else { return AgentToolCallResult(output: "No routine of yours matches “\(value("id").isEmpty ? value("name") : value("id"))”. Use action=list.") }
            if let gated = gate("Turn routine “\(routine.name)” back on — \(Cron.formatCron(routine.cron))") { return gated }
            setRoutineActive(routine.id, active: true)
            return AgentToolCallResult(output: "Resumed “\(routine.name)”.")

        case "delete":
            guard let routine = find() else { return AgentToolCallResult(output: "No routine of yours matches “\(value("id").isEmpty ? value("name") : value("id"))”. Use action=list.") }
            if let gated = gate("Delete routine “\(routine.name)”") { return gated }
            deleteRoutine(routine.id)
            return AgentToolCallResult(output: "Deleted “\(routine.name)”.")

        default:
            return AgentToolCallResult(output: "action must be create, list, pause, resume, or delete.")
        }
    }
}
