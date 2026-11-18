import Foundation

/// Which departments a Chief of Staff answers for. Authority follows departments: a Chief is in charge of
/// its own department and of any the person ticked under "Also in charge of". Reaching and messaging a
/// bot is never limited by department ("folders, not walls"); this only decides who may stop or delete
/// another bot without having spawned it or handed it the job.
extension AppStore {
    /// The most departments one Chief can be put in charge of.
    public static let maxManagedDepartments = 100

    /// Every department there is, General ("") first.
    public var allDepartmentKeys: [String] { teamMapSections.map(\.key) }

    /// True when `chief` is the Chief of Staff and is in charge of `department` ("" is General).
    public func isInCharge(_ chief: Bot, of department: String) -> Bool {
        chief.chiefOfStaff && (department == self.department(of: chief.id) || chief.managedDepartments.contains(department))
    }

    /// May `botId` stop or delete `targetId` on authority alone? Only a Chief, never over itself or over
    /// another Chief, and only in a department it is in charge of.
    public func hasAuthority(_ botId: String, over targetId: String) -> Bool {
        guard botId != targetId,
              let chief = bots.first(where: { $0.id == botId }), chief.chiefOfStaff,
              let target = bots.first(where: { $0.id == targetId }), !target.chiefOfStaff
        else { return false }
        return isInCharge(chief, of: department(of: target.id))
    }

    /// Why a Chief may not manage `target`, and the one step that changes it. Names are person-typed, so flattened.
    public func authorityRefusal(chief: Bot, target: Bot) -> String {
        func flat(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ") }
        let dept = department(of: target.id)
        let label = dept.isEmpty ? "General" : flat(dept)
        if target.chiefOfStaff { return "\(flat(target.name)) is the Chief of Staff; nobody stops or deletes the Chief this way." }
        return "\(flat(target.name)) is in the \(label) department, which \(flat(chief.name)) is not in charge of. "
            + "Only the person can add a department, in \(flat(chief.name))'s bot settings under \"Also in charge of\"."
    }

    /// The Chief is told what it answers for, so it never has to guess. Empty for every other bot.
    public func authorityNote(forBot botId: String) -> String {
        guard let chief = bots.first(where: { $0.id == botId }), chief.chiefOfStaff else { return "" }
        let own = department(of: chief.id)
        let names = ([own] + chief.managedDepartments.filter { $0 != own && allDepartmentKeys.contains($0) })
            .map { $0.isEmpty ? "General" : $0.replacingOccurrences(of: "\n", with: " ") }
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        return "You are in charge of these departments: \(list). In them you may stop a running bot (stop_bot) or delete one (delete_bot, by exact name) even if you did not create it or hand it the job. "
            + "You cannot do this to bots in other departments, and you can still message any bot. Only the person can put you in charge of more departments, in your bot settings under \"Also in charge of\"."
    }

    /// Sets the departments (besides its own) a Chief is in charge of. Only the person calls this, from
    /// settings. Names that are not departments are dropped, duplicates collapse, order follows the Team map.
    @discardableResult
    public func setManagedDepartments(_ botId: String, _ names: [String]) -> Bool {
        guard let i = bots.firstIndex(where: { $0.id == botId }), bots[i].chiefOfStaff else { return false }
        let own = department(of: botId)
        let wanted = Set(names)
        let valid = allDepartmentKeys.filter { wanted.contains($0) && $0 != own }
        guard valid.count <= Self.maxManagedDepartments else { return false }
        bots[i].managedDepartments = valid
        save()
        return true
    }

    /// A Chief already in charge of every department gets each new one too, the way the person's tick
    /// would. A Chief in charge of only some gets nothing. Called before the new name joins the list.
    func grantNewDepartment(_ name: String) {
        let existing = allDepartmentKeys
        for i in bots.indices where bots[i].chiefOfStaff {
            let chief = bots[i]
            guard existing.allSatisfy({ isInCharge(chief, of: $0) }),
                  !chief.managedDepartments.contains(name),
                  chief.managedDepartments.count < Self.maxManagedDepartments else { continue }
            bots[i].managedDepartments.append(name)
        }
    }

    /// Carries a rename into every Chief's list.
    func renameManagedDepartment(_ old: String, to name: String) {
        for i in bots.indices where bots[i].managedDepartments.contains(old) {
            bots[i].managedDepartments = bots[i].managedDepartments.map { $0 == old ? name : $0 }
        }
    }

    /// Drops a deleted department from every Chief's list.
    func dropManagedDepartment(_ name: String) {
        for i in bots.indices { bots[i].managedDepartments.removeAll { $0 == name } }
    }
}
