import Foundation
import Observation

// Working and granted folders.
extension AppStore {
    /// File tools resolve here for the current run (watcher watch path, else the bot folder).
    public func effectiveWorkingFolder(for bot: Bot) -> String? {
        let override = runWorkingFolderOverride[bot.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return bot.workingFolder
    }

    /// Folders from Settings → Folders that this bot has been assigned.
    public func grantedFolders(for bot: Bot) -> [GrantedFolder] {
        grantedFolders.filter { bot.grantedFolderIds.contains($0.id) }
    }

    @discardableResult
    public func addGrantedFolder(path: String, name: String? = nil) -> GrantedFolder? {
        let expanded = BotHomeStore.expandPath(path)
        guard !expanded.isEmpty, !BotHomeStore.isDeniedHostPath(expanded) else { return nil }
        let standard = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if let existing = grantedFolders.first(where: { BotHomeStore.expandPath($0.path) == standard }) { return existing }
        let label = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = GrantedFolder(name: label.isEmpty ? (standard as NSString).lastPathComponent : label, path: standard)
        grantedFolders.append(folder)
        save()
        return folder
    }

    public func removeGrantedFolder(_ id: String) {
        grantedFolders.removeAll { $0.id == id }
        for idx in bots.indices { bots[idx].grantedFolderIds.removeAll { $0 == id } }
        save()
    }

    public func renameGrantedFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = grantedFolders.firstIndex(where: { $0.id == id }) else { return }
        grantedFolders[idx].name = trimmed
        save()
    }

    public func setBotFolder(_ botId: String, folderId: String, granted: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].grantedFolderIds.removeAll { $0 == folderId }
        if granted { bots[idx].grantedFolderIds.append(folderId) }
        bots[idx].updatedAt = .now
        save()
    }

    func extraShellWriteRoots(for bot: Bot) -> [String] {
        var roots = GrantedFolders.writeRoots(grantedFolders(for: bot))
        guard let folder = effectiveWorkingFolder(for: bot)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return roots }
        let expanded = BotHomeStore.expandPath(folder)
        guard WorkingFolder.isTrusted(expanded, workingFolder: expanded) else { return roots }
        roots.append(expanded)
        return roots
    }
}
