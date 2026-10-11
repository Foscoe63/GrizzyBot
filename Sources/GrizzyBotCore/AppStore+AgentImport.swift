import Foundation

/// What the person is shown before an agent folder becomes a bot.
public struct AgentFolderPreview: Sendable {
    public var manifest: AgentFolderManifest
    public var fileCount: Int
    public var report: SkillScanReport
}

extension AppStore {
    public func previewAgentFolder(_ folder: URL) throws -> AgentFolderPreview {
        let manifest = try AgentFolder.read(folder)
        return AgentFolderPreview(
            manifest: manifest,
            fileCount: try AgentFolder.files(in: folder).count,
            report: AgentFolder.scan(manifest)
        )
    }

    /// Makes a normal bot from an agent folder: its skill is saved to the skill library and switched
    /// on for the bot, the whole folder is copied into the bot's home so the skill's references can
    /// be read, and the name, description and colour come from the folder's agent file.
    @discardableResult
    public func importAgentFolder(_ preview: AgentFolderPreview) throws -> Bot {
        let manifest = preview.manifest
        let files = try AgentFolder.files(in: manifest.folder)

        try SkillLibrary.saveUserSkill(manifest.skill, root: userPersistence.root)
        reloadSkills()
        let skillId = SkillMarkdown.slug(manifest.skill.id)

        let importDir = "imports/\(skillId)"
        let note = """
        You were created from an imported agent folder ("\(manifest.name)"). Its skill is \(skillId): load it with read_skill. \
        The skill's reference files are in your home folder under \(importDir)/ — wherever the skill names a path such as \
        references/api.md, read \(importDir)/references/api.md.
        """
        let instructions = [manifest.skill.description, note]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")

        let bot = createBot(
            name: manifest.name,
            title: String(manifest.summary.prefix(80)),
            description: manifest.summary,
            instructions: instructions,
            enabledSkills: BundledSkills.ids + [skillId]
        )
        if let hex = manifest.brandColor, let idx = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[idx].color = hex
        }

        let home = try botHome.homeURL(botId: bot.id).appendingPathComponent(importDir, isDirectory: true)
        let fm = FileManager.default
        for rel in files {
            let source = manifest.folder.appendingPathComponent(rel)
            let target = home.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
        save()
        return bots.first { $0.id == bot.id } ?? bot
    }
}
