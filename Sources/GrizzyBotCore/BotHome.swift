import Foundation

/// Sandboxed per-bot home filesystem (rakazo `LocalAgentHomeStore`).
/// Paths are always contained under `homes/{botId}/` inside the app data root.
public struct BotHomeStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.appendingPathComponent("homes", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func homeURL(botId: String) throws -> URL {
        let safe = try Self.validateBotId(botId)
        let dir = root.appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String
        public var isDirectory: Bool
        public var size: Int64
    }

    public func list(botId: String, directory: String = "") throws -> [Entry] {
        let home = try homeURL(botId: botId)
        let dir = try resolveExisting(botId: botId, relative: directory, mustBeDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return try names.sorted().compactMap { name -> Entry? in
            let child = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir) else { return nil }
            let rel = relativePath(from: home, to: child)
            let attrs = try FileManager.default.attributesOfItem(atPath: child.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return Entry(path: rel, isDirectory: isDir.boolValue, size: size)
        }
    }

    public func read(botId: String, path: String) throws -> String {
        let url = try resolveExisting(botId: botId, relative: path, mustBeDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(botId: String, path: String, content: String) throws {
        let url = try resolveWritable(botId: botId, relative: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func edit(botId: String, path: String, content: String, mode: EditMode = .replace) throws {
        switch mode {
        case .replace:
            try write(botId: botId, path: path, content: content)
        case .append:
            let existing = (try? read(botId: botId, path: path)) ?? ""
            try write(botId: botId, path: path, content: existing + content)
        }
    }

    public enum EditMode: String, Sendable {
        case replace
        case append
    }

    public func move(botId: String, from: String, to: String) throws {
        let src = try resolveExisting(botId: botId, relative: from, mustBeDirectory: nil)
        let dest = try resolveWritable(botId: botId, relative: to)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: src, to: dest)
    }

    public func delete(botId: String, path: String) throws {
        let url = try resolveExisting(botId: botId, relative: path, mustBeDirectory: nil)
        try FileManager.default.removeItem(at: url)
    }

    public func exists(botId: String, path: String) -> Bool {
        (try? resolveExisting(botId: botId, relative: path, mustBeDirectory: nil)) != nil
    }

    public func allFilesFlat(botId: String) throws -> [[String]] {
        let home = try homeURL(botId: botId)
        var out: [[String]] = []
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = relativePath(from: home, to: url)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out.append([rel, content])
        }
        return out.sorted { ($0.first ?? "") < ($1.first ?? "") }
    }

    // MARK: - Path safety

    private static func validateBotId(_ botId: String) throws -> String {
        let trimmed = botId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw BotHomeError.invalidBotId
        }
        return trimmed
    }

    private func resolveExisting(botId: String, relative: String, mustBeDirectory: Bool?) throws -> URL {
        let home = try homeURL(botId: botId)
        let candidate = try containedURL(home: home, relative: relative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) else {
            throw BotHomeError.notFound(relative)
        }
        if let mustBeDirectory {
            if mustBeDirectory != isDir.boolValue {
                throw BotHomeError.wrongType(relative)
            }
        }
        return candidate
    }

    private func resolveWritable(botId: String, relative: String) throws -> URL {
        let home = try homeURL(botId: botId)
        return try containedURL(home: home, relative: relative)
    }

    private func containedURL(home: URL, relative: String) throws -> URL {
        let cleaned = relative
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
        if cleaned.isEmpty { return home }
        let parts = cleaned.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else {
            throw BotHomeError.pathEscapes
        }
        var url = home
        for part in parts {
            url = url.appendingPathComponent(part)
        }
        let homePath = home.resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved == homePath || resolved.hasPrefix(homePath + "/") else {
            throw BotHomeError.pathEscapes
        }
        return url
    }

    private func relativePath(from home: URL, to url: URL) -> String {
        let homePath = home.path
        let full = url.path
        if full == homePath { return "" }
        if full.hasPrefix(homePath + "/") {
            return String(full.dropFirst(homePath.count + 1))
        }
        return url.lastPathComponent
    }
}

public enum BotHomeError: Error, LocalizedError, Sendable, Equatable {
    case invalidBotId
    case pathEscapes
    case notFound(String)
    case wrongType(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBotId: return "Invalid bot id"
        case .pathEscapes: return "Path escapes bot home"
        case .notFound(let p): return "Not found: \(p)"
        case .wrongType(let p): return "Wrong type: \(p)"
        }
    }
}
