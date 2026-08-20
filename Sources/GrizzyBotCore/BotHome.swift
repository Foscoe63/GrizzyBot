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

    /// Bot-home relative path, or an absolute/`~` path on this Mac (read-only).
    public func readFlexible(botId: String, path: String) throws -> String {
        if Self.isHostPath(path) {
            let url = try Self.hostURL(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw BotHomeError.notFound(path)
            }
            if isDir.boolValue { throw BotHomeError.wrongType(path) }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try read(botId: botId, path: path)
    }

    /// Bot-home directory, or an absolute/`~` folder on this Mac.
    public func listFlexible(botId: String, directory: String = "") throws -> [Entry] {
        if Self.isHostPath(directory) {
            let url = try Self.hostURL(directory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw BotHomeError.notFound(directory)
            }
            guard isDir.boolValue else { throw BotHomeError.wrongType(directory) }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return try names.sorted().compactMap { name -> Entry? in
                let child = url.appendingPathComponent(name)
                var childDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childDir) else { return nil }
                let attrs = try FileManager.default.attributesOfItem(atPath: child.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                return Entry(path: child.path, isDirectory: childDir.boolValue, size: size)
            }
        }
        do {
            return try list(botId: botId, directory: directory)
        } catch BotHomeError.notFound {
            return []
        }
    }

    public static func isHostPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    public static func expandPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    public static func isDeniedHostPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: expandPath(path)).standardizedFileURL
        let parts = url.pathComponents.map { $0.lowercased() }
        let secretDirs: Set<String> = [".ssh", ".gnupg", ".aws"]
        if parts.contains(where: { secretDirs.contains($0) }) { return true }
        let name = url.lastPathComponent.lowercased()
        if name == "id_rsa" || name.hasPrefix("id_rsa.") { return true }
        if name == "id_ed25519" || name.hasPrefix("id_ed25519.") { return true }
        if name == ".netrc" || name == ".env" || name.hasPrefix(".env.") { return true }
        return false
    }

    private static func hostURL(_ path: String) throws -> URL {
        let expanded = expandPath(path)
        guard isHostPath(path) else { throw BotHomeError.pathEscapes }
        if isDeniedHostPath(expanded) { throw BotHomeError.hostDenied }
        return URL(fileURLWithPath: expanded)
    }

    public func write(botId: String, path: String, content: String) throws {
        let url = try resolveWritable(botId: botId, relative: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Copy an external file into the bot home. Returns the relative destination path.
    @discardableResult
    public func importFile(botId: String, from source: URL, relative dest: String? = nil) throws -> String {
        let name = source.lastPathComponent
        let relative = dest?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let relative, !relative.isEmpty {
            path = relative
        } else {
            path = "inbox/\(name)"
        }
        let url = try resolveWritable(botId: botId, relative: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: source, to: url)
        return path
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

    public enum ShellTimeout {
        public static let `default`: TimeInterval = 120
        public static let min: TimeInterval = 5
        public static let max: TimeInterval = 300

        public static func clamp(_ seconds: TimeInterval?) -> TimeInterval {
            guard let seconds, seconds > 0 else { return `default` }
            return Swift.min(max, Swift.max(min, seconds))
        }

        public static func parse(_ raw: String) -> TimeInterval {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Double(trimmed) else { return `default` }
            return clamp(value)
        }
    }

    public struct ShellResult: Sendable, Equatable {
        public var exitCode: Int
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool

        public init(exitCode: Int, stdout: String, stderr: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }

        public var combined: String {
            var parts: [String] = []
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { parts.append(out) }
            if !err.isEmpty { parts.append(err) }
            if timedOut { parts.append("(timed out)") }
            if parts.isEmpty { return "exit \(exitCode)" }
            return parts.joined(separator: "\n") + "\nexit \(exitCode)"
        }
    }

    /// Run a command with cwd inside this bot's home. Does not leave the home as cwd.
    public func runShell(
        botId: String,
        command: String,
        cwd: String = "",
        timeout: TimeInterval = ShellTimeout.default
    ) async throws -> ShellResult {
        let home = try homeURL(botId: botId)
        let directory = try containedURL(home: home, relative: cwd)
        var isDir: ObjCBool = false
        if cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                throw BotHomeError.wrongType(cwd)
            }
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ShellResult(exitCode: 1, stdout: "", stderr: "empty command")
        }
        return try await Self.exec(command: trimmed, cwd: directory, home: home, timeout: timeout)
    }

    private static func exec(
        command: String,
        cwd: URL,
        home: URL,
        timeout: TimeInterval
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runProcess(command: command, cwd: cwd, home: home, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProcess(
        command: String,
        cwd: URL,
        home: URL,
        timeout: TimeInterval
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", seatbeltProfile(home: home), "/bin/zsh", "-lc", command]
        process.currentDirectoryURL = cwd
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
        }
        process.environment = [
            "HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG": "en_US.UTF-8",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        try process.run()
        let wait = group.wait(timeout: .now() + timeout)
        var timedOut = false
        if wait == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ShellResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(stdout.prefix(20_000)),
            stderr: String(stderr.prefix(8_000)),
            timedOut: timedOut
        )
    }

    private static func seatbeltProfile(home: URL) -> String {
        let tmp = FileManager.default.temporaryDirectory
        func allowWrite(_ url: URL) -> String {
            let paths = seatbeltPaths(url)
            return paths.map { path in
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "(allow file-write* (subpath \"\(escaped)\"))"
            }.joined(separator: "\n")
        }
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        \(allowWrite(home))
        (allow file-write* (subpath "/private/tmp"))
        (allow file-write* (subpath "/tmp"))
        \(allowWrite(tmp))
        (allow file-write-data (literal "/dev/null"))
        (allow file-ioctl)
        (allow sysctl-read)
        """
    }

    /// Seatbelt matches the kernel path (`/private/var/...`), not the `/var` symlink.
    private static func seatbeltPaths(_ url: URL) -> [String] {
        var paths: [String] = []
        func add(_ raw: String) {
            guard !raw.isEmpty, !paths.contains(raw) else { return }
            paths.append(raw)
            if raw.hasPrefix("/var/") { add("/private" + raw) }
            if raw.hasPrefix("/tmp") { add("/private" + raw) }
            if raw.hasPrefix("/private/var/") {
                let alias = String(raw.dropFirst("/private".count))
                if !paths.contains(alias) { paths.append(alias) }
            }
        }
        add(url.path)
        add(url.standardizedFileURL.path)
        add(url.resolvingSymlinksInPath().path)
        return paths
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
    case hostDenied

    public var errorDescription: String? {
        switch self {
        case .invalidBotId: return "Invalid bot id"
        case .pathEscapes: return "Path escapes bot home"
        case .notFound(let p): return "Not found: \(p)"
        case .wrongType(let p): return "Wrong type: \(p)"
        case .hostDenied: return "That path is blocked (secrets). Ask the user to paste the file if they need it."
        }
    }
}
