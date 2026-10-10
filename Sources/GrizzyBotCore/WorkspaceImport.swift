import Foundation

/// Reads an OpenClaw-style agent workspace (`SOUL.md`, `AGENTS.md`, `MEMORY.md`, `HEARTBEAT.md`, `skills/`)
/// so someone moving over keeps their agent's character and notes. Hermes and other tools that follow the
/// same convention work too. Reading only: nothing in the source folder is changed.
public struct WorkspaceImportPlan: Equatable, Sendable {
    public var name: String
    public var instructions: String
    public var memory: String
    public var heartbeat: String
    public var skillsFolder: URL?
    public var found: [String]

    public var isEmpty: Bool { found.isEmpty }

    public func preview() -> String {
        guard !found.isEmpty else { return "No agent files found in that folder." }
        return "Found: " + found.joined(separator: ", ") + ".\nA new bot “\(name)” will be created from it. Skills are scanned and left switched off; a heartbeat checklist becomes a paused routine."
    }
}

public enum WorkspaceImport {
    static let maxFileBytes = 200_000

    public static func plan(folder: URL) -> WorkspaceImportPlan {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            let url = folder.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.size] as? Int ?? 0) <= maxFileBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
        var found: [String] = []
        var sections: [String] = []
        for (file, label) in [("SOUL.md", "Character"), ("IDENTITY.md", "Identity"), ("AGENTS.md", "Operating rules"), ("USER.md", "About the person"), ("TOOLS.md", "Tool notes")] {
            if let text = read(file) {
                found.append(file)
                sections.append("## \(label)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        var memory = read("MEMORY.md") ?? ""
        if !memory.isEmpty { found.append("MEMORY.md") }
        // Daily notes under memory/ are history, not standing facts; mention them but keep the memory file lean.
        if let notes = try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("memory").path).filter({ $0.hasSuffix(".md") }), !notes.isEmpty {
            found.append("memory/ (\(notes.count) notes, not imported)")
        }
        let heartbeat = read("HEARTBEAT.md") ?? ""
        if !heartbeat.isEmpty { found.append("HEARTBEAT.md") }
        var skills: URL?
        let skillsDir = folder.appendingPathComponent("skills")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue {
            skills = skillsDir
            found.append("skills/")
        }
        if memory.count > 20_000 { memory = String(memory.prefix(20_000)) }
        let name = folder.lastPathComponent == "workspace"
            ? folder.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            : folder.lastPathComponent
        return WorkspaceImportPlan(
            name: name.isEmpty ? "Imported" : name.prefix(1).uppercased() + name.dropFirst(),
            instructions: sections.joined(separator: "\n\n"),
            memory: memory,
            heartbeat: heartbeat,
            skillsFolder: skills,
            found: found
        )
    }
}

extension AppStore {
    /// Creates a bot from the plan. Returns it, or nil when there was nothing to import.
    @discardableResult
    public func importWorkspace(_ plan: WorkspaceImportPlan) -> (bot: Bot, skillReports: [(id: String, risk: SkillScanReport.Risk)])? {
        guard !plan.isEmpty else { return nil }
        let bot = createBot(
            name: plan.name,
            title: "Imported",
            description: "Imported from an agent workspace.",
            instructions: DiagnosticScrubber.redact(plan.instructions)
        )
        if !plan.memory.isEmpty {
            let note = "# Memory\n\n## Facts\n" + plan.memory
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> String in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return text.hasPrefix("- ") || text.hasPrefix("#") ? text : "- \(text)"
                }
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            try? botHome.write(botId: bot.id, path: MemoryFiles.botFileName, content: DiagnosticScrubber.redact(note))
            ingestMemoryFileIfNeeded(botId: bot.id, path: MemoryFiles.botFileName)
        }
        if !plan.heartbeat.isEmpty {
            if let hb = createHeartbeat(botId: bot.id, name: "Heartbeat", checklist: plan.heartbeat) {
                if let loc = routineLocation(hb.id) { routines[loc.0]?[loc.1].active = false }
            }
        }
        var reports: [(String, SkillScanReport.Risk)] = []
        if let folder = plan.skillsFolder,
           let scanned = try? SkillLibrary.importScanned(folder, into: userPersistence.root) {
            reloadSkills()
            reports = scanned.map { ($0.skill.id, $0.report.risk) }
        }
        save()
        return (bot, reports)
    }
}
