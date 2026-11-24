import Foundation

// `team_map`: a bot reads and organizes the Team map for the person. Reading is free; every change stops on
// an approval card only a person can answer, so a bot can't quietly reshuffle the team.
extension AppStore {
    func teamMapManage(bot: Bot, argumentsJSON: String, approved: Bool, taint: RunTaint?) -> AgentToolCallResult {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        func value(_ key: String) -> String { (args.stringValue(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let department = value("department")
        func gate(_ detail: String) -> AgentToolCallResult? {
            if approved { return nil }
            let why = taint?.isTainted == true ? " (this run has read outside content)" : ""
            return humanGate(tool: "team.change", detail: detail + why, argumentsJSON: argumentsJSON)
        }
        func section(_ name: String) -> TeamMapSection? {
            teamMapSections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.key.caseInsensitiveCompare(name) == .orderedSame }
        }
        func describe(_ s: TeamMapSection) -> String {
            let chiefs = s.chiefs.map { "\($0.name) (chief)" }
            let names = chiefs + s.members.map(\.name)
            return "- \(s.name): \(names.isEmpty ? "no bots" : names.joined(separator: ", "))"
        }

        switch value("action").lowercased() {
        case "list", "":
            let sections = teamMapSections
            guard !sections.isEmpty else { return AgentToolCallResult(output: "The Team map has no teams yet.") }
            return AgentToolCallResult(
                output: sections.map(describe).joined(separator: "\n"),
                blocks: [.card(lines: sections.prefix(8).map { CardLine(k: $0.name, v: "\($0.count) bot\($0.count == 1 ? "" : "s")") })]
            )
        case "get":
            guard let s = section(department) else { return AgentToolCallResult(output: "No team named “\(department)”. Use action=list.") }
            let brief = departmentInstructions(s.key)?.text ?? "none"
            return AgentToolCallResult(output: describe(s) + "\nShared instructions: " + brief)
        case "create":
            guard !department.isEmpty else { return AgentToolCallResult(output: "department is required") }
            if section(department) != nil { return AgentToolCallResult(output: "A team named “\(department)” already exists.") }
            if let gated = gate("Create team “\(department)”") { return gated }
            var ids: [String] = []
            if !value("bot").isEmpty, case .found(let b) = BotLookup.resolve([value("bot")], in: bots) { ids = [b.id] }
            return AgentToolCallResult(output: createDepartment(department, botIds: ids) ? "Created team “\(department)”." : "Couldn't create “\(department)”.")
        case "rename":
            guard let s = section(department), !s.key.isEmpty else { return AgentToolCallResult(output: "No team named “\(department)” to rename.") }
            let new = value("new_name")
            guard !new.isEmpty else { return AgentToolCallResult(output: "new_name is required") }
            if let gated = gate("Rename team “\(s.name)” to “\(new)”") { return gated }
            return AgentToolCallResult(output: renameDepartment(s.key, to: new) ? "Renamed to “\(new)”." : "Couldn't rename (name empty or taken).")
        case "delete":
            guard let s = section(department), !s.key.isEmpty else { return AgentToolCallResult(output: "No team named “\(department)” to delete.") }
            if let gated = gate("Delete team “\(s.name)”; its bots go back to General") { return gated }
            deleteDepartment(s.key)
            return AgentToolCallResult(output: "Deleted team “\(s.name)”. Its bots are in General.")
        case "assign":
            guard case .found(let target) = BotLookup.resolve([value("bot")], in: bots) else {
                return AgentToolCallResult(output: "No single bot matches “\(value("bot"))”.")
            }
            var key = ""
            if !department.isEmpty && department.caseInsensitiveCompare("General") != .orderedSame {
                guard let s = section(department) else { return AgentToolCallResult(output: "No team named “\(department)”. Create it first.") }
                key = s.key
            }
            if let gated = gate("Move \(target.name) to \(key.isEmpty ? "General" : key)") { return gated }
            moveBot(target.id, toDepartment: key)
            return AgentToolCallResult(output: "Moved \(target.name) to \(key.isEmpty ? "General" : key).")
        case "set_instructions":
            guard let s = section(department.isEmpty ? "General" : department) else { return AgentToolCallResult(output: "No team named “\(department)”.") }
            let text = (args.stringValue("text") ?? "")
            if let gated = gate("Set shared instructions for \(s.name): \(String(text.prefix(240)))") { return gated }
            switch setDepartmentInstructions(s.key, text: text) {
            case .saved: return AgentToolCallResult(output: "Saved instructions for \(s.name).")
            case .cleared: return AgentToolCallResult(output: "Cleared instructions for \(s.name).")
            case .tooLong(let b, let l): return AgentToolCallResult(output: "Too long: \(b) bytes, limit \(l).")
            case .unknownDepartment: return AgentToolCallResult(output: "No team named “\(department)”.")
            }
        default:
            return AgentToolCallResult(output: "action must be list, get, create, rename, delete, assign, or set_instructions.")
        }
    }
}
