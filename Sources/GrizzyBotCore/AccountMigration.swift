import Foundation

/// Moves legacy flat Application Support files into per-user directories.
public enum AccountMigration {
    private static let markerName = ".multi-user-migrated"

    public static func migrateIfNeeded(globalRoot: URL) {
        let marker = globalRoot.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: globalRoot, withIntermediateDirectories: true)

        migratePasswordHashes(globalRoot: globalRoot)
        migrateWorkspaces(globalRoot: globalRoot)
        migrateSnapshots(globalRoot: globalRoot)
        migrateHomes(globalRoot: globalRoot)
        migrateDiagnostics(globalRoot: globalRoot)
        migrateDestinations(globalRoot: globalRoot)
        migrateSkills(globalRoot: globalRoot)

        try? Data().write(to: marker)
    }

    private static func migratePasswordHashes(globalRoot: URL) {
        let usersURL = globalRoot.appendingPathComponent("users.json")
        guard let data = try? Data(contentsOf: usersURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var records = try? decoder.decode([UserAccountRecord].self, from: data) else { return }

        var changed = false
        for index in records.indices {
            guard let hash = records[index].passwordHash, !hash.isEmpty else { continue }
            try? AccountCredentialStore.save(userId: records[index].id, passwordHash: hash)
            records[index].passwordHash = nil
            changed = true
        }
        guard changed else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let out = try? encoder.encode(records.map(UserAccount.init(record:))) else { return }
        try? out.write(to: usersURL, options: .atomic)
    }

    private static func migrateWorkspaces(globalRoot: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: globalRoot.path) else { return }
        for name in names where name.hasPrefix("user-") && name.hasSuffix(".json") {
            let userId = String(name.dropFirst("user-".count).dropLast(".json".count))
            let source = globalRoot.appendingPathComponent(name)
            let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
            let dest = userDir.appendingPathComponent("workspace.json")
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: source, to: dest)
            }
        }
    }

    private static func migrateSnapshots(globalRoot: URL) {
        let snapshotsRoot = globalRoot.appendingPathComponent("snapshots", isDirectory: true)
        guard let userIds = try? FileManager.default.contentsOfDirectory(atPath: snapshotsRoot.path) else { return }
        for userId in userIds {
            let source = snapshotsRoot.appendingPathComponent(userId, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
            let dest = userDir.appendingPathComponent("snapshots", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: source, to: dest)
            }
        }
        try? FileManager.default.removeItem(at: snapshotsRoot)
    }

    private static func migrateHomes(globalRoot: URL) {
        let homes = globalRoot.appendingPathComponent("homes", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: homes.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        guard let userId = primaryUserId(globalRoot: globalRoot) else { return }
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        let dest = userDir.appendingPathComponent("homes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.moveItem(at: homes, to: dest)
        }
    }

    private static func migrateDiagnostics(globalRoot: URL) {
        let diagnostics = globalRoot.appendingPathComponent("Diagnostics", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: diagnostics.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        guard let userId = primaryUserId(globalRoot: globalRoot) else { return }
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        let dest = userDir.appendingPathComponent("Diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.moveItem(at: diagnostics, to: dest)
        }
    }

    private static func migrateDestinations(globalRoot: URL) {
        let source = globalRoot.appendingPathComponent("destinations.json")
        guard FileManager.default.fileExists(atPath: source.path),
              let userId = primaryUserId(globalRoot: globalRoot)
        else { return }
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        let dest = userDir.appendingPathComponent("destinations.json")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.moveItem(at: source, to: dest)
        }
    }

    private static func migrateSkills(globalRoot: URL) {
        let skills = globalRoot.appendingPathComponent("skills", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skills.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        guard let userId = primaryUserId(globalRoot: globalRoot) else { return }
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        let dest = userDir.appendingPathComponent("skills", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.moveItem(at: skills, to: dest)
        }
    }

    private static func primaryUserId(globalRoot: URL) -> String? {
        if let session = Persistence(root: globalRoot).loadSession() {
            return session.userId
        }
        let users = Persistence(root: globalRoot).loadUsers()
        if users.count == 1 { return users[0].id }
        if let local = users.first(where: { $0.email == "local@grizzybot.local" }) {
            return local.id
        }
        return users.first?.id
    }
}

private struct UserAccountRecord: Codable {
    var id: String
    var email: String
    var name: String
    var createdAt: Date?
    var passwordHash: String?
}

private extension UserAccount {
    init(record: UserAccountRecord) {
        self.init(
            id: record.id,
            email: record.email,
            name: record.name,
            createdAt: record.createdAt ?? .now
        )
    }
}
