import Foundation

/// A department's shared notes. Bots propose and search from their tools; only the person accepts, edits,
/// pins and deletes. Proposals never reach a prompt.
extension AppStore {
    private func factsKey(_ department: String) -> String { department.trimmingCharacters(in: .whitespaces) }

    private func requireDepartment(_ key: String) throws {
        if !key.isEmpty, !teamMapSections.contains(where: { $0.key == key }) { throw DepartmentMemoryError.unknownDepartment }
    }

    /// Notes still in play (accepted and proposed), proposals first, then pinned, then newest.
    public func departmentFacts(_ department: String) -> [DepartmentFact] {
        (teamMap.facts[factsKey(department)] ?? []).filter(\.isActive)
            .sorted { (rank($0), $0.updatedAt) > (rank($1), $1.updatedAt) }
    }

    private func rank(_ f: DepartmentFact) -> Int { f.status == .proposed ? 2 : (f.pinned ? 1 : 0) }

    public func pendingFactCount(_ department: String) -> Int {
        (teamMap.facts[factsKey(department)] ?? []).filter { $0.status == .proposed }.count
    }

    /// Proposals waiting across every department, for a badge.
    public var totalPendingFacts: Int { teamMap.facts.values.reduce(0) { $0 + $1.filter { $0.status == .proposed }.count } }

    /// What goes in a bot's prompt: its own department's accepted notes, or "".
    public func departmentMemoryPrompt(forBot botId: String) -> String {
        let dept = department(of: botId)
        return DepartmentMemory.promptSelection(teamMap.facts[dept] ?? [], department: dept).text
    }

    /// Which accepted notes the prompt actually loads, so the dialog can say so.
    public func departmentMemorySelection(_ department: String) -> DepartmentMemory.Selection {
        DepartmentMemory.promptSelection(teamMap.facts[factsKey(department)] ?? [], department: department)
    }

    private func mutate(_ department: String, _ change: (inout [DepartmentFact]) throws -> Void) throws {
        let key = factsKey(department)
        try requireDepartment(key)
        var list = teamMap.facts[key] ?? []
        try change(&list)
        teamMap.facts[key] = list.isEmpty ? nil : list
        save()
    }

    /// A bot's proposal, filed in its own department as "proposed".
    @discardableResult
    public func proposeDepartmentFact(botId: String, _ input: DepartmentFactInput) throws -> DepartmentFact {
        let name = bots.first(where: { $0.id == botId })?.name ?? "a bot"
        var made: DepartmentFact?
        try mutate(department(of: botId)) { made = try DepartmentMemory.propose(&$0, input, sourceBotId: botId, sourceName: name) }
        return made!
    }

    /// The person adds a note straight into the accepted list.
    @discardableResult
    public func addDepartmentFact(_ department: String, _ input: DepartmentFactInput) throws -> DepartmentFact {
        var made: DepartmentFact?
        try mutate(department) { made = try DepartmentMemory.add(&$0, input) }
        return made!
    }

    @discardableResult
    public func resolveDepartmentFact(_ department: String, id: String, accept: Bool, expectedRevision: Int? = nil) throws -> DepartmentMemory.Resolution {
        var result = DepartmentMemory.Resolution.rejected
        try mutate(department) { result = try DepartmentMemory.resolve(&$0, id: id, accept: accept, expectedRevision: expectedRevision) }
        return result
    }

    @discardableResult
    public func updateDepartmentFact(_ department: String, id: String, patch: DepartmentFactPatch, expectedRevision: Int? = nil) throws -> DepartmentFact {
        var made: DepartmentFact?
        try mutate(department) { made = try DepartmentMemory.update(&$0, id: id, patch: patch, expectedRevision: expectedRevision) }
        return made!
    }

    public func removeDepartmentFact(_ department: String, id: String, expectedRevision: Int? = nil) throws {
        try mutate(department) { try DepartmentMemory.remove(&$0, id: id, expectedRevision: expectedRevision) }
    }

    /// Notes the prompt left out, found by words, for the bot's own department.
    public func searchDepartmentFacts(botId: String, query: String, limit: Int = 12) -> [DepartmentFact] {
        DepartmentMemory.search(teamMap.facts[department(of: botId)] ?? [], query: query, limit: limit)
    }
}
