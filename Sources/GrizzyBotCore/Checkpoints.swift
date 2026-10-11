import Foundation

/// A safety net under the file tools: before a bot overwrites, moves, or deletes a file, the file's
/// previous state is copied aside, so `/rollback` can undo a bad run. Shell commands are not covered —
/// only `write_file`, `edit_file`, `move_file`, and `delete_file`.
public struct Checkpoint: Codable, Sendable, Equatable, Identifiable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Absolute path that was touched.
        public var path: String
        /// False when the file did not exist yet (rollback removes it).
        public var existed: Bool
        /// Name of the copy inside the checkpoint folder.
        public var backup: String?
    }

    public var id: String
    public var runId: String?
    public var label: String
    public var createdAt: Date
    public var entries: [Entry]
}

public enum CheckpointStore {
    public static let maxKept = 30
    public static let maxFileBytes = 25 * 1024 * 1024

    static func root(home: URL) -> URL {
        home.appendingPathComponent(".checkpoints", isDirectory: true)
    }

    private static func folder(home: URL, id: String) -> URL {
        root(home: home).appendingPathComponent(id, isDirectory: true)
    }

    /// Remember how these paths look right now. Paths already captured by this run keep their
    /// earliest state, so rolling back a run returns to before it started.
    @discardableResult
    public static func record(home: URL, runId: String?, label: String, paths: [String], now: Date = .now) -> Checkpoint? {
        let fm = FileManager.default
        let unique = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
        guard !unique.isEmpty else { return nil }

        var checkpoint: Checkpoint
        if let runId, let latest = list(home: home).first, latest.runId == runId {
            checkpoint = latest
        } else {
            checkpoint = Checkpoint(id: "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))", runId: runId, label: label, createdAt: now, entries: [])
        }
        let dir = folder(home: home, id: checkpoint.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var added = false
        for path in unique where !checkpoint.entries.contains(where: { $0.path == path }) {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            guard exists else {
                checkpoint.entries.append(.init(path: path, existed: false, backup: nil))
                added = true
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: path)
            if !isDir.boolValue, (attrs?[.size] as? Int ?? 0) > maxFileBytes { continue }
            let name = "\(checkpoint.entries.count)"
            do {
                try fm.copyItem(atPath: path, toPath: dir.appendingPathComponent(name).path)
                checkpoint.entries.append(.init(path: path, existed: true, backup: name))
                added = true
            } catch {
                continue
            }
        }
        guard added || !checkpoint.entries.isEmpty else { return nil }
        if let data = try? JSONEncoder().encode(checkpoint) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
        prune(home: home)
        return checkpoint
    }

    /// Newest first.
    public static func list(home: URL) -> [Checkpoint] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root(home: home).path) else { return [] }
        return names.compactMap { name -> Checkpoint? in
            let url = folder(home: home, id: name).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Checkpoint.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Puts every file in the checkpoint back as it was, then discards the checkpoint.
    /// Returns the paths that were restored or removed.
    @discardableResult
    public static func rollback(home: URL, id: String? = nil) -> (checkpoint: Checkpoint, restored: [String])? {
        let all = list(home: home)
        guard let target = id.flatMap({ wanted in all.first { $0.id == wanted || $0.id.hasPrefix(wanted) } }) ?? (id == nil ? all.first : nil) else {
            return nil
        }
        let fm = FileManager.default
        let dir = folder(home: home, id: target.id)
        var restored: [String] = []
        // Undo in reverse so a file moved twice ends where it started.
        for entry in target.entries.reversed() {
            let url = URL(fileURLWithPath: entry.path)
            if entry.existed, let backup = entry.backup {
                try? fm.removeItem(at: url)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.copyItem(at: dir.appendingPathComponent(backup), to: url)) != nil {
                    restored.append(entry.path)
                }
            } else if fm.fileExists(atPath: entry.path) {
                if (try? fm.removeItem(at: url)) != nil { restored.append(entry.path) }
            }
        }
        try? fm.removeItem(at: dir)
        return (target, restored)
    }

    private static func prune(home: URL) {
        let all = list(home: home)
        guard all.count > maxKept else { return }
        for old in all.dropFirst(maxKept) {
            try? FileManager.default.removeItem(at: folder(home: home, id: old.id))
        }
    }

    public static func describe(_ checkpoints: [Checkpoint], limit: Int = 8) -> String {
        guard !checkpoints.isEmpty else { return "No checkpoints yet. They're saved automatically before a bot changes files." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let lines = checkpoints.prefix(limit).map { cp -> String in
            let names = cp.entries.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            let more = cp.entries.count > 3 ? " +\(cp.entries.count - 3) more" : ""
            return "• `\(cp.id.prefix(12))` \(formatter.localizedString(for: cp.createdAt, relativeTo: .now)) — \(names)\(more)"
        }
        return "Checkpoints (newest first):\n" + lines.joined(separator: "\n") + "\n\n`/rollback` undoes the newest. `/rollback <id>` undoes a specific one."
    }
}
