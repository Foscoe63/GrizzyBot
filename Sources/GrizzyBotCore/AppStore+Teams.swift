import Foundation

extension AppStore {
    /// Builds a package from the chosen bots (all visible bots when none are named).
    public func exportTeamPackage(name: String, summary: String = "", botIds: [String]? = nil) -> TeamPackage {
        let chosen = bots.filter { bot in
            !bot.hidden && (botIds?.contains(bot.id) ?? true)
        }
        let nameOf = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.name) })
        let validTools = Set(AgentToolCatalog.allIds)
        let specs = chosen.map { bot in
            TeamPackage.BotSpec(
                name: bot.name,
                title: bot.title,
                description: DiagnosticScrubber.redact(bot.description),
                instructions: DiagnosticScrubber.redact(bot.instructions),
                skills: bot.enabledSkills,
                tools: bot.enabledTools.filter { validTools.contains($0) },
                chiefOfStaff: bot.chiefOfStaff,
                goal: bot.goal.map(DiagnosticScrubber.redact)
            )
        }
        let routineSpecs = chosen.flatMap { bot in
            (routines[bot.id] ?? []).map { r in
                TeamPackage.RoutineSpec(
                    bot: bot.name, name: r.name, prompt: DiagnosticScrubber.redact(r.prompt),
                    cron: r.cron, heartbeat: r.heartbeat, continuity: r.continuity
                )
            }
        }
        let roomSpecs = groups.compactMap { group -> TeamPackage.RoomSpec? in
            let members = group.memberIds.compactMap { nameOf[$0] }
            return members.count >= 2 ? TeamPackage.RoomSpec(name: group.name, members: members) : nil
        }
        return TeamPackage(name: name, summary: summary, bots: specs, rooms: roomSpecs, routines: routineSpecs)
    }

    /// Creates the bots, rooms, and (paused) routines. Imported bots ask before they act, and skills that
    /// did not ship with GrizzyBot stay off until the person turns them on.
    @discardableResult
    public func importTeamPackage(_ package: TeamPackage) -> [Bot] {
        let installed = Set(skills.map(\.id))
        let bundled = Set(BundledSkills.ids)
        let validTools = Set(AgentToolCatalog.allIds)
        var created: [Bot] = []
        var byName: [String: Bot] = [:]
        for spec in package.bots.prefix(TeamPackage.maxBots) {
            let name = uniqueBotName(spec.name)
            var bot = createBot(
                name: name,
                title: spec.title,
                description: spec.description,
                instructions: spec.instructions,
                enabledSkills: spec.skills.filter { bundled.contains($0) && installed.contains($0) },
                enabledTools: spec.tools.filter { validTools.contains($0) }
            )
            if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                bots[idx].autoApprove = false
                bots[idx].goal = spec.goal
                bot = bots[idx]
            }
            created.append(bot)
            byName[spec.name] = bot
            if spec.chiefOfStaff, !bots.contains(where: { $0.chiefOfStaff }) {
                setChiefOfStaff(bot.id, enabled: true)
            }
        }
        for room in package.rooms {
            let ids = room.members.compactMap { byName[$0]?.id }
            if ids.count >= 2 { _ = createGroup(name: room.name, memberIds: ids) }
        }
        for r in package.routines {
            guard let owner = byName[r.bot] else { continue }
            let routine = createRoutine(botId: owner.id, name: r.name, prompt: r.prompt, cron: r.cron, active: false)
            setRoutineOptions(routine.id, continuity: r.continuity, heartbeat: r.heartbeat)
        }
        save()
        return created
    }

    private func uniqueBotName(_ wanted: String) -> String {
        let existing = Set(bots.map { $0.name.lowercased() })
        guard existing.contains(wanted.lowercased()) else { return wanted }
        var n = 2
        while existing.contains("\(wanted) \(n)".lowercased()) { n += 1 }
        return "\(wanted) \(n)"
    }
}
