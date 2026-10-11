import Foundation

/// Lending a tool to the bot you hand a job to. A delegate runs with its own tools and no more, so a
/// job that needs one it lacks (a researcher with no shell, say) used to fail slowly. Now the lead can
/// say so up front: it can lend a tool it has itself, for that one job, if the person agrees — and the
/// borrowed tool is approved by the person at every use, whatever the delegate's auto-approve says.
public enum DelegateTools {
    /// Tools worth lending. Memory, secrets, routines, delegation, plugins and the computer are not.
    public static let lendable: [String] = ["shell", "read_file", "write_file", "edit_file", "list_files", "web_search"]

    public static func parseGrant(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Abilities the task plainly asks for that this bot has no tool for. Uses the router's narrow cues,
    /// so ordinary words don't count.
    public static func missingAbilities(task: String, peer: BotProfile) -> [BotAbility] {
        let text = " " + task.lowercased() + " "
        return BotAbility.allCases.filter { ability in
            !ability.cues.isEmpty && !peer.has(ability) && ability.cues.contains { text.contains($0) }
        }
    }

    /// The tool ids to lend so that `ability` works, when it can be lent at all.
    public static func lendTools(for ability: BotAbility) -> [String] {
        switch ability {
        case .shell: return ["shell"]
        case .files: return ["read_file", "write_file", "list_files"]
        case .web: return ["web_search"]
        default: return []
        }
    }
}

/// A borrowed set of tools, good for one run of one bot.
struct LentTools {
    var tools: Set<String>
    /// The run that was current when the loan was made; a different run id means the job has started.
    var previousRunId: String?
    var runId: String?
}

enum DelegateToolPlan {
    case refuse(String)
    case proceed(lend: [String])
}

extension AppStore {
    /// What a bot may use right now beyond its own switches: only while the job it was lent for runs.
    public func lentTools(for botId: String) -> Set<String> {
        guard var record = lentToolRecords[botId] else { return [] }
        let run = threads[threadKey(for: botId)]?.run
        if record.runId == nil, let run, run.id != record.previousRunId { record.runId = run.id }
        if let run, record.runId != nil {
            let finished = run.status == .completed || run.status == .failed || run.status == .cancelled
            if run.id != record.runId || finished {
                lentToolRecords[botId] = nil
                return []
            }
        }
        lentToolRecords[botId] = record
        return record.tools
    }

    /// The bot as it runs this job: the borrowed tools switched on, and every approval-gated action
    /// asking the person, whatever its own settings say.
    func runtimeBot(_ bot: Bot) -> Bot {
        let lent = lentTools(for: bot.id)
        guard !lent.isEmpty else { return bot }
        var copy = bot
        for tool in lent.sorted() where !copy.enabledTools.contains(tool) { copy.enabledTools.append(tool) }
        copy.autoApprove = false
        copy.alwaysAllowTools = []
        copy.allowRules = []
        return copy
    }

    func delegateToolPlan(lead: Bot, peer: Bot, task: String, grant: [String], force: Bool) -> DelegateToolPlan {
        let notLendable = grant.filter { !DelegateTools.lendable.contains($0) }
        if !notLendable.isEmpty {
            return .refuse("grant_tools can only lend: \(DelegateTools.lendable.joined(separator: ", ")). “\(notLendable.joined(separator: ", "))” can't be lent.")
        }
        var lend: [String] = []
        for tool in grant where !peer.isToolEnabled(tool) {
            guard lead.isToolEnabled(tool) else {
                return .refuse("You don't have \(tool) yourself, so you can't lend it to \(peer.name).")
            }
            lend.append(tool)
        }

        if !force {
            let missing = DelegateTools.missingAbilities(task: task, peer: profile(for: peer))
                .filter { ability in !ability.tools.contains { lend.contains($0) } }
            if !missing.isEmpty {
                let labels = missing.map(\.label).joined(separator: ", ")
                var text = "\(peer.name) has no \(labels) tool, and this job needs it."
                let others = bots.filter { candidate in
                    let candidateProfile = profile(for: candidate)
                    return candidate.id != lead.id && candidate.id != peer.id && !candidate.hidden
                        && missing.allSatisfy { candidateProfile.has($0) }
                }.map(\.name)
                if !others.isEmpty { text += " Bots that have it: \(others.prefix(5).joined(separator: ", ")) — hand it to one of them." }
                let lendable = missing.flatMap { DelegateTools.lendTools(for: $0) }.filter { lead.isToolEnabled($0) }
                if !lendable.isEmpty, lendable.count == missing.flatMap({ DelegateTools.lendTools(for: $0) }).count {
                    text += " Or lend it for this job: send again with grant_tools=\"\(lendable.joined(separator: ","))\" (the person is asked, and approves each use)."
                }
                text += " Or do the part that needs it yourself. To send it anyway, pass anyway=true."
                return .refuse(text)
            }
        }
        return .proceed(lend: lend)
    }
}
