import Foundation

extension AppStore {
    /// Builds a package from the chosen bots (all visible bots when none are named).
    public func exportTeamPackage(name: String, summary: String = "", botIds: [String]? = nil,
        connectors: [TeamPackage.ConnectorSpec] = [], departments: [TeamPackage.DepartmentSpec] = [],
        departmentByBotId: [String: String] = [:]
    ) -> TeamPackage {
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
        var depts = departments
        if depts.isEmpty, !departmentByBotId.isEmpty {
            var byName: [String: String] = [:]
            for bot in chosen { if let d = departmentByBotId[bot.id] { byName[bot.name] = d } }
            depts = TeamPackage.departments(from: byName, rooms: roomSpecs, order: chosen.map(\.name))
        }
        return TeamPackage(name: name, summary: summary, bots: specs, rooms: roomSpecs, routines: routineSpecs,
                           connectors: connectors, departments: depts)
    }

    /// Accounts the person has connected, as checklist entries an author can pick from when sharing.
    public var connectableAccounts: [TeamPackage.ConnectorSpec] {
        connections.filter(\.connected).map { TeamPackage.ConnectorSpec(slug: $0.slug, name: $0.name) }
    }

    /// Puts a team in front of the person for review. Nothing is created yet.
    public func proposeTeam(_ package: TeamPackage) {
        pendingTeamPackage = package
    }

    /// Reads a team file from disk (double-click, drop, or picker) and proposes it.
    public func proposeTeam(file url: URL) throws {
        proposeTeam(try TeamPackage.load(file: url))
    }

    /// Closes the review without importing (or after it finished).
    public func dismissPendingTeam() {
        pendingTeamPackage = nil
    }

    /// Imports the pending team, optionally only some departments. Returns the bots created. The team
    /// stays pending so the review can show what happened; call `dismissPendingTeam()` when done.
    @discardableResult
    public func confirmPendingTeam(departments names: [String]? = nil, includeUngrouped: Bool = true) -> [Bot] {
        guard let package = pendingTeamPackage else { return [] }
        let chosen: TeamPackage
        if let names, !package.departments.isEmpty {
            chosen = package.restricted(toDepartments: names, includeUngrouped: includeUngrouped)
        } else {
            chosen = package
        }
        return importTeamPackage(chosen)
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
        for dept in package.departments {
            let ids = dept.bots.compactMap { byName[$0]?.id }
            let alreadyRoom = package.rooms.contains { Set($0.members) == Set(dept.bots) }
            if ids.count >= 2, !alreadyRoom { _ = createGroup(name: dept.name, memberIds: ids) }
        }
        save()
        return created
    }

    /// Which of a team's suggested accounts are connected here and which still need setting up.
    public func connectorChecklist(for package: TeamPackage) -> (connected: [TeamPackage.ConnectorSpec], missing: [TeamPackage.ConnectorSpec]) {
        let live = Set(connections.filter(\.connected).map { $0.slug.lowercased() })
        let have = package.connectors.filter { live.contains($0.slug.lowercased()) }
        let need = package.connectors.filter { !live.contains($0.slug.lowercased()) }
        return (have, need)
    }

    private func uniqueBotName(_ wanted: String) -> String {
        let existing = Set(bots.map { $0.name.lowercased() })
        guard existing.contains(wanted.lowercased()) else { return wanted }
        var n = 2
        while existing.contains("\(wanted) \(n)".lowercased()) { n += 1 }
        return "\(wanted) \(n)"
    }
}

// MARK: - Team map

extension AppStore {
    public func department(of botId: String) -> String {
        (teamMap.assignments[botId] ?? "").trimmingCharacters(in: .whitespaces)
    }

    public var teamMapSections: [TeamMapSection] { TeamMapLogic.sections(bots: bots, state: teamMap) }

    private func departmentExists(_ name: String) -> Bool {
        let all = teamMap.departments + teamMap.assignments.values
        return all.contains { $0.caseInsensitiveCompare(name) == .orderedSame } || name.caseInsensitiveCompare("General") == .orderedSame
    }

    /// Makes a department, optionally moving bots into it. False when the name is empty or taken.
    @discardableResult
    public func createDepartment(_ rawName: String, botIds: [String] = []) -> Bool {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, !departmentExists(name) else { return false }
        grantNewDepartment(name)
        teamMap.departments.append(name)
        for id in botIds { moveBot(id, toDepartment: name, save: false) }
        save()
        return true
    }

    @discardableResult
    public func renameDepartment(_ old: String, to rawName: String) -> Bool {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !old.isEmpty, !name.isEmpty, name != old, !departmentExists(name) else { return false }
        teamMap.departments = teamMap.departments.map { $0 == old ? name : $0 }
        if !teamMap.departments.contains(name) { teamMap.departments.append(name) }
        for (id, dept) in teamMap.assignments where dept == old { teamMap.assignments[id] = name }
        if let p = teamMap.positions.removeValue(forKey: old) { teamMap.positions[name] = p }
        if let o = teamMap.botOrders.removeValue(forKey: old) { teamMap.botOrders[name] = o }
        if let brief = teamMap.instructions.removeValue(forKey: old) { teamMap.instructions[name] = brief }
        if let notes = teamMap.facts.removeValue(forKey: old) { teamMap.facts[name] = notes }
        renameManagedDepartment(old, to: name)
        save()
        return true
    }

    /// Removes the department; its bots go back to General and are kept.
    public func deleteDepartment(_ name: String) {
        guard !name.isEmpty else { return }
        teamMap.departments.removeAll { $0 == name }
        teamMap.assignments = teamMap.assignments.filter { $0.value != name }
        teamMap.positions[name] = nil
        teamMap.botOrders[name] = nil
        teamMap.instructions[name] = nil
        teamMap.facts[name] = nil
        dropManagedDepartment(name)
        save()
    }

    /// Billed tokens per department over the last `days` days.
    public func departmentUsage(days: Int = 7, now: Date = .now) -> [DepartmentUsage] {
        TeamMapLogic.usageByDepartment(usage, since: now.addingTimeInterval(-Double(days) * 86_400), sections: teamMapSections)
    }

    // MARK: Shared instructions

    public enum DepartmentInstructionsResult: Equatable, Sendable {
        case saved
        case cleared
        case tooLong(bytes: Int, limit: Int)
        case unknownDepartment
    }

    /// The saved brief for a department ("" is General), or nil when there is none.
    public func departmentInstructions(_ department: String) -> DepartmentInstructions? {
        teamMap.instructions[department.trimmingCharacters(in: .whitespaces)]
    }

    /// Saves, replaces or (for blank text) clears a department's shared instructions. Refuses text over the
    /// byte limit without touching what is saved, and a department that does not exist.
    @discardableResult
    public func setDepartmentInstructions(_ department: String, text: String, now: Date = .now) -> DepartmentInstructionsResult {
        let key = department.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, !teamMapSections.contains(where: { $0.key == key }) { return .unknownDepartment }
        let bytes = DepartmentInstructions.byteCount(text)
        guard bytes <= DepartmentInstructions.maxBytes else { return .tooLong(bytes: bytes, limit: DepartmentInstructions.maxBytes) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let had = teamMap.instructions.removeValue(forKey: key) != nil
            if had { save() }
            return .cleared
        }
        teamMap.instructions[key] = DepartmentInstructions(text: text, updatedAt: now)
        save()
        return .saved
    }

    /// The block that goes into this bot's system prompt: its own department's brief, or "".
    public func departmentInstructionsPrompt(forBot botId: String) -> String {
        let dept = department(of: botId)
        guard let brief = teamMap.instructions[dept] else { return "" }
        return TeamMapLogic.instructionsPrompt(department: dept, text: brief.text)
    }

    /// Moves a bot to a department ("" is General); it lands at the end of its lane.
    public func moveBot(_ botId: String, toDepartment dept: String, save persist: Bool = true) {
        guard bots.contains(where: { $0.id == botId }) else { return }
        if dept.isEmpty { teamMap.assignments[botId] = nil } else { teamMap.assignments[botId] = dept }
        for key in Array(teamMap.botOrders.keys) { teamMap.botOrders[key]?.removeAll { $0 == botId } }
        if persist { save() }
    }

    /// Puts `botId` at `index` among the bots of its own kind (Chiefs or members) in its department.
    public func arrangeBot(_ botId: String, toIndex index: Int) {
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let dept = department(of: botId)
        guard let section = teamMapSections.first(where: { $0.key == dept }) else { return }
        let lane = (bot.chiefOfStaff ? section.chiefs : section.members).map(\.id)
        let other = (bot.chiefOfStaff ? section.members : section.chiefs).map(\.id)
        teamMap.botOrders[dept] = TeamMapLogic.reorder(lane, moving: botId, to: index) + other
        save()
    }

    public func setDepartmentPosition(_ dept: String, _ point: CanvasPoint) {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < 100_000, abs(point.y) < 100_000 else { return }
        teamMap.positions[dept] = point
        save()
    }

    public func setShowScreens(_ on: Bool) {
        teamMap.showScreens = on
        save()
    }

    /// Sends what was typed on the map. Each addressed bot gets it as a normal message in its own chat;
    /// `@everyone` goes to the Chief of Staff, which passes it on. Returns who got it.
    @discardableResult
    public func sendFromTeamMap(_ text: String) -> (botIds: [String], chief: Bot?) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = TeamMapLogic.targets(text: message, bots: bots, state: teamMap)
        guard !message.isEmpty, !targets.botIds.isEmpty else { return ([], nil) }
        let delivery = TeamMapLogic.delivery(for: targets, bots: bots, state: teamMap)
        for id in delivery.botIds { send(botId: id, text: message) }
        return delivery
    }
}
