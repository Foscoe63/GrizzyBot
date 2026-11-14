import Foundation
import Observation

// Per-bot and shared memory, and skill management.
extension AppStore {
    func upsertMemory(botId: String, text: String) {
        _ = rememberFact(botId: botId, text: text, shared: false)
    }

    func upsertSharedMemory(text: String) {
        _ = rememberFact(botId: "", text: text, shared: true)
    }

    public func botMemory(botId: String) -> String {
        memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
    }

    public func setBotMemory(botId: String, text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MemoryLedger.botTemplate
            : text
        replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: content)
        try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: content)
        save()
    }

    @discardableResult
    func rememberFact(botId: String, text: String, shared: Bool, pin: Bool = false, untrusted: Bool = false) -> MemoryWriteResult {
        let title = shared ? MemoryLedger.sharedTitle : MemoryLedger.botTitle
        let current = shared ? sharedMemory : botMemory(botId: botId)
        let seed = MemoryLedger.isSparse(current) ? MemoryLedger.template(shared: shared) : current
        let written = MemoryLedger.upsert(content: seed, fact: text, title: title, pin: pin, untrusted: untrusted)
        guard written.result != .rejectedSecret, written.result != .empty else { return written.result }
        if shared {
            replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: written.text)
            MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: written.text)
        } else {
            replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: written.text)
            try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: written.text)
        }
        save()
        return written.result
    }

    @discardableResult
    func forgetFacts(botId: String, query: String, shared: Bool) -> [String] {
        let current = shared ? sharedMemory : botMemory(botId: botId)
        let result = MemoryLedger.forget(content: current, query: query)
        guard !result.removed.isEmpty else { return [] }
        if shared {
            replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: result.text)
            MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: result.text)
        } else {
            replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: result.text)
            try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: result.text)
        }
        save()
        return result.removed
    }

    func hydrateMemoryFiles() {
        let sharedURL = MemoryFiles.sharedURL(root: userPersistence.root)
        let jsonShared = memory.first(where: { $0.scope == "workspace" && $0.path == MemoryFiles.sharedFileName })?.content ?? ""
        let diskShared = MemoryFiles.read(sharedURL) ?? ""
        let sharedText: String
        if !MemoryLedger.isSparse(diskShared) {
            sharedText = diskShared
        } else if !MemoryLedger.isSparse(jsonShared) {
            sharedText = jsonShared
        } else {
            sharedText = MemoryLedger.sharedTemplate
        }
        replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: sharedText)
        MemoryFiles.write(sharedURL, content: sharedText)

        for bot in bots {
            let json = memory.first(where: { $0.botId == bot.id && $0.path == MemoryFiles.botFileName })?.content ?? ""
            let disk = (try? botHome.read(botId: bot.id, path: MemoryFiles.botFileName)) ?? ""
            let text: String
            if !MemoryLedger.isSparse(disk) {
                text = disk
            } else if !MemoryLedger.isSparse(json) {
                text = json
            } else {
                text = MemoryLedger.botTemplate
            }
            replaceMemoryDocument(scope: "bot", botId: bot.id, path: MemoryFiles.botFileName, content: text)
            try? botHome.write(botId: bot.id, path: MemoryFiles.botFileName, content: text)
        }
    }

    func persistMemoryFiles() {
        let shared = sharedMemory.isEmpty ? MemoryLedger.sharedTemplate : sharedMemory
        MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: shared)
        for bot in bots {
            let text = botMemory(botId: bot.id)
            try? botHome.write(
                botId: bot.id,
                path: MemoryFiles.botFileName,
                content: text.isEmpty ? MemoryLedger.botTemplate : text
            )
        }
    }

    func ingestMemoryFileIfNeeded(botId: String, path: String) {
        guard URL(fileURLWithPath: path).lastPathComponent == MemoryFiles.botFileName else { return }
        let text = (try? botHome.read(botId: botId, path: MemoryFiles.botFileName)) ?? MemoryLedger.botTemplate
        replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: text)
    }

    func replaceMemoryDocument(scope: String, botId: String?, path: String, content: String) {
        let idx: Int?
        if path == MemoryFiles.sharedFileName {
            idx = memory.firstIndex(where: { $0.scope == "workspace" && $0.path == path })
        } else {
            idx = memory.firstIndex(where: { $0.botId == botId && $0.path == path })
        }
        if let idx {
            memory[idx].content = content
            memory[idx].revision += 1
            memory[idx].updatedAt = .now
            if memory[idx].scope.isEmpty { memory[idx].scope = scope }
            if memory[idx].botId == nil { memory[idx].botId = botId }
        } else {
            memory.append(
                MemoryDocument(
                    id: Ids.new(),
                    scope: scope,
                    botId: botId,
                    path: path,
                    content: content
                )
            )
        }
    }

    public var sharedMemory: String {
        memory.first(where: { $0.scope == "workspace" && $0.path == "SHARED.md" })?.content ?? ""
    }

    public func setSharedMemory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.isEmpty ? MemoryLedger.sharedTemplate : text
        replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: content)
        MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: content)
        save()
    }

    func skills(for bot: Bot) -> [AgentSkill] {
        skills.filter { bot.enabledSkills.contains($0.id) }
    }

    /// Skills enabled for a bot (composer `/` autocomplete).
    public func enabledSkills(for botId: String) -> [AgentSkill] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        return skills(for: bot)
    }

    public func reloadSkills() {
        skills = SkillLibrary.load(root: userPersistence.root)
    }

    public func setBotSkill(_ botId: String, skillId: String, enabled: Bool) {
        setBotSkills(botId, skillIds: [skillId], enabled: enabled)
    }

    /// Bulk form for the profile's Enable all / Disable all.
    public func setBotSkills(_ botId: String, skillIds: [String], enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        for id in skillIds {
            bots[idx].setSkill(id, enabled: enabled)
        }
        bots[idx].updatedAt = .now
        save()
    }

    /// Every skill in the library, whether or not this bot has it on.
    public func setAllBotSkills(_ botId: String, enabled: Bool) {
        setBotSkills(botId, skillIds: skills.map(\.id), enabled: enabled)
        // Disable all means none, including ids the library no longer has (a template can
        // name skills that aren't installed).
        if !enabled, let idx = bots.firstIndex(where: { $0.id == botId }), !bots[idx].enabledSkills.isEmpty {
            bots[idx].enabledSkills = []
            save()
        }
    }

    public func installUserSkill(id: String, description: String, body: String) throws {
        try installUserSkill(
            AgentSkill(
                id: SkillMarkdown.slug(id),
                name: id,
                description: description,
                body: body,
                source: .user
            )
        )
    }

    /// Whole-skill install, so a SKILL.md edited as a document keeps the fields
    /// the three-field form has no box for — `keywords` and `allowed-tools`.
    public func installUserSkill(_ skill: AgentSkill) throws {
        var stored = skill
        stored.id = SkillMarkdown.slug(skill.id)
        stored.source = .user
        try SkillLibrary.saveUserSkill(stored, root: userPersistence.root)
        reloadSkills()
        for i in bots.indices where !bots[i].enabledSkills.contains(stored.id) {
            bots[i].enabledSkills.append(stored.id)
        }
        save()
    }

    public func deleteUserSkill(_ id: String) throws {
        try SkillLibrary.deleteUserSkill(id: id, root: userPersistence.root)
        reloadSkills()
        for i in bots.indices {
            bots[i].enabledSkills.removeAll { $0 == id }
        }
        save()
    }
}
