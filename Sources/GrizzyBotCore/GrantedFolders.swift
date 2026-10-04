import Foundation

/// A host folder the user granted read/write access to. Bots only reach it once it is assigned to them.
public struct GrantedFolder: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var createdAt: Date

    public init(id: String = Ids.new(), name: String, path: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }
}

public enum GrantedFolders {
    /// True when `path` is inside one of the folders and is not a secret location (.ssh, .env, …).
    public static func contains(_ path: String, in folders: [GrantedFolder]) -> Bool {
        folders.contains { WorkingFolder.isTrusted(path, workingFolder: $0.path) }
    }

    /// Tells the model which folders it may use and that paths must be absolute.
    public static func promptNote(_ folders: [GrantedFolder]) -> String {
        guard !folders.isEmpty else { return "" }
        let lines = folders.map { "- \($0.name): \(BotHomeStore.expandPath($0.path))" }.joined(separator: "\n")
        return """
        Granted folders (read and write, no approval needed). Use absolute paths with read_file, write_file, edit_file, move_file, delete_file, and list_files; shell may also write there.
        \(lines)
        """
    }

    /// Folders that exist on disk, standardized, for the shell sandbox's write roots.
    public static func writeRoots(_ folders: [GrantedFolder]) -> [String] {
        folders.compactMap { folder in
            let expanded = BotHomeStore.expandPath(folder.path)
            guard !expanded.isEmpty, !BotHomeStore.isDeniedHostPath(expanded) else { return nil }
            return expanded
        }
    }
}
