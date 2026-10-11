import Foundation

// Skill usage, proposals, and the curator's suggestions.
extension AppStore {
    func recordSkillUse(_ id: String) {
        var usage = SkillUsageStore.load(root: userPersistence.root)
        usage.recordUse(id)
        usage.save(root: userPersistence.root)
    }

    /// A bot's draft skill: saved, scanned, and left switched off until a person says yes.
    public func proposeSkill(botId: String, id: String, description: String, body: String, keywords: String) -> AgentToolCallResult {
        let slug = SkillMarkdown.slug(id)
        guard !slug.isEmpty else { return AgentToolCallResult(output: "id is required") }
        guard !description.isEmpty, !body.isEmpty else { return AgentToolCallResult(output: "description and body are required") }
        if skills.contains(where: { $0.id == slug && $0.source == .bundled }) {
            return AgentToolCallResult(output: "\(slug) is a built-in skill and cannot be replaced. Pick another id.")
        }
        if let existing = skills.first(where: { $0.id == slug }), existing.source == .user {
            let usage = SkillUsageStore.load(root: userPersistence.root)
            if usage.records[slug]?.awaitingReview != true {
                return AgentToolCallResult(output: "A skill named \(slug) already exists. Pick another id; proposals never overwrite a skill that is in use.")
            }
        }
        let skill = AgentSkill(
            id: slug,
            name: slug,
            description: description,
            body: body,
            source: .user,
            keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        let report = SkillScanner.scan(skill)
        if report.risk == .danger {
            return AgentToolCallResult(output: "Not saved — the scanner flagged it:\n\(report.summary)")
        }
        if MemoryLedger.looksLikeSecret(body) || MemoryLedger.looksLikeSecret(description) {
            return AgentToolCallResult(output: "Not saved — it looks like it contains a secret.")
        }
        do {
            try SkillLibrary.saveUserSkill(skill, root: userPersistence.root)
        } catch {
            return AgentToolCallResult(output: "Could not save the proposal: \(error.localizedDescription)")
        }
        var usage = SkillUsageStore.load(root: userPersistence.root)
        var record = usage.records[slug] ?? SkillUsageRecord(firstSeen: .now)
        record.proposedBy = botId
        record.awaitingReview = true
        usage.records[slug] = record
        usage.save(root: userPersistence.root)
        reloadSkills()
        return AgentToolCallResult(
            output: "Saved \(slug) as a proposal. It is switched off until the person reviews it in Skills.",
            blocks: [.card(lines: [
                CardLine(k: "proposed skill", v: slug),
                CardLine(k: "status", v: report.risk == .clean ? "awaiting review" : "awaiting review · \(report.risk.label)"),
            ])]
        )
    }

    // MARK: - Review

    public func skillsAwaitingReview() -> [AgentSkill] {
        let usage = SkillUsageStore.load(root: userPersistence.root)
        return skills.filter { usage.records[$0.id]?.awaitingReview == true }
    }

    /// The person's yes: turn a proposal on for every bot.
    public func approveSkillProposal(_ id: String) throws {
        guard let skill = skills.first(where: { $0.id == id }) else { return }
        var usage = SkillUsageStore.load(root: userPersistence.root)
        usage.records[id]?.awaitingReview = false
        usage.save(root: userPersistence.root)
        try installUserSkill(skill)
    }

    /// The person's no: archive it (never a hard delete) and stop asking.
    public func rejectSkillProposal(_ id: String) throws {
        try archiveSkill(id)
    }

    public func curatorSuggestions(now: Date = .now) -> [CuratorSuggestion] {
        var usage = SkillUsageStore.load(root: userPersistence.root)
        usage.noteSkills(skills.map(\.id), now: now)
        usage.save(root: userPersistence.root)
        return SkillCurator.review(skills: skills, usage: usage, now: now)
    }

    public func archiveSkill(_ id: String) throws {
        try SkillLibrary.archiveUserSkill(id: id, root: userPersistence.root)
        var usage = SkillUsageStore.load(root: userPersistence.root)
        usage.records[id]?.awaitingReview = false
        usage.save(root: userPersistence.root)
        reloadSkills()
        for i in bots.indices { bots[i].enabledSkills.removeAll { $0 == id } }
        save()
    }

    public func archivedSkillNames() -> [String] {
        SkillLibrary.archivedNames(root: userPersistence.root)
    }

    public func restoreSkill(archivedName: String) throws {
        _ = try SkillLibrary.restoreArchived(name: archivedName, root: userPersistence.root)
        reloadSkills()
    }

    public func setSkillPinned(_ id: String, pinned: Bool) {
        var usage = SkillUsageStore.load(root: userPersistence.root)
        var record = usage.records[id] ?? SkillUsageRecord(firstSeen: .now)
        record.pinned = pinned
        usage.records[id] = record
        usage.save(root: userPersistence.root)
    }

    public func skillUsage(_ id: String) -> SkillUsageRecord? {
        SkillUsageStore.load(root: userPersistence.root).records[id]
    }
}
