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

    public func writeFlexible(botId: String, path: String, content: String) throws {
        if Self.isHostPath(path) {
            let url = try Self.hostURL(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        try write(botId: botId, path: path, content: content)
    }

    public func editFlexible(botId: String, path: String, content: String, mode: EditMode = .replace) throws {
        switch mode {
        case .replace:
            try writeFlexible(botId: botId, path: path, content: content)
        case .append:
            let existing = (try? readFlexible(botId: botId, path: path)) ?? ""
            try writeFlexible(botId: botId, path: path, content: existing + content)
        }
    }

    public func moveFlexible(botId: String, from: String, to: String) throws {
        if Self.isHostPath(from) || Self.isHostPath(to) {
            let src = try Self.hostURL(from)
            let dest = try Self.hostURL(to)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: src, to: dest)
            return
        }
        try move(botId: botId, from: from, to: to)
    }

    public func deleteFlexible(botId: String, path: String) throws {
        if Self.isHostPath(path) {
            let url = try Self.hostURL(path)
            try FileManager.default.removeItem(at: url)
            return
        }
        try delete(botId: botId, path: path)
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
            if exitCode != 0, err.contains("Operation not permitted") {
                parts.append("(The shell sandbox only lets commands write inside the bot home and the working folder. Use write_file to save elsewhere, or report the real path you wrote to.)")
            }
            if exitCode != 0, err.localizedCaseInsensitiveContains("could not resolve host")
                || err.localizedCaseInsensitiveContains("couldn't resolve host")
                || err.localizedCaseInsensitiveContains("network is unreachable") {
                parts.append("(Shell network access may be off for this bot. It can be enabled in the bot's settings.)")
            }
            if parts.isEmpty { return "exit \(exitCode)" }
            return parts.joined(separator: "\n") + "\nexit \(exitCode)"
        }
    }

    /// Run a command with cwd inside this bot's home. Does not leave the home as cwd.
    /// `extraWriteRoots` are additional host folders the seatbelt may write (working folder / watch path).
    public func runShell(
        botId: String,
        command: String,
        cwd: String = "",
        timeout: TimeInterval = ShellTimeout.default,
        extraWriteRoots: [String] = [],
        allowNetwork: Bool = false
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
        return try await Self.exec(
            command: trimmed,
            cwd: directory,
            home: home,
            extraWriteRoots: Self.sanitizedWriteRoots(extraWriteRoots),
            allowNetwork: allowNetwork,
            timeout: timeout
        )
    }

    private static func sanitizedWriteRoots(_ raw: [String]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for item in raw {
            let expanded = expandPath(item)
            guard !expanded.isEmpty, !isDeniedHostPath(expanded) else { continue }
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            let key = url.path
            guard seen.insert(key).inserted else { continue }
            out.append(url)
        }
        return out
    }

    private static func exec(
        command: String,
        cwd: URL,
        home: URL,
        extraWriteRoots: [URL],
        allowNetwork: Bool,
        timeout: TimeInterval
    ) async throws -> ShellResult {
        let handle = ShellProcessHandle()
        let result: ShellResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runProcess(
                            command: command,
                            cwd: cwd,
                            home: home,
                            extraWriteRoots: extraWriteRoots,
                            allowNetwork: allowNetwork,
                            timeout: timeout,
                            handle: handle
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
        // Stop kills the command's whole process group; surface it as a cancellation.
        try Task.checkCancellation()
        return result
    }

    /// Runs the command in its own process group so a timeout or Stop takes down its
    /// children too, and reads both pipes while it runs so output past the 64 KB pipe
    /// buffer can't wedge the command.
    private static func runProcess(
        command: String,
        cwd: URL,
        home: URL,
        extraWriteRoots: [URL],
        allowNetwork: Bool,
        timeout: TimeInterval,
        handle: ShellProcessHandle
    ) throws -> ShellResult {
        var executable = "/usr/bin/sandbox-exec"
        var arguments = [
            "sandbox-exec", "-p",
            seatbeltProfile(home: home, extraWriteRoots: extraWriteRoots, allowNetwork: allowNetwork),
            "/bin/zsh", "-lc", command,
        ]
        if !FileManager.default.isExecutableFile(atPath: executable) {
            executable = "/bin/zsh"
            arguments = ["zsh", "-lc", command]
        }
        let environment = [
            "HOME=\(home.path)",
            "TMPDIR=\(NSTemporaryDirectory())",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "LANG=en_US.UTF-8",
        ]

        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { throw BotHomeError.shellLaunch("pipe failed") }
        guard pipe(&errFds) == 0 else {
            close(outFds[0]); close(outFds[1])
            throw BotHomeError.shellLaunch("pipe failed")
        }
        // Keep concurrent launches from inheriting each other's pipe ends.
        for fd in outFds + errFds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outFds[1])
        close(errFds[1])
        guard spawned == 0 else {
            close(outFds[0]); close(errFds[0])
            throw BotHomeError.shellLaunch(String(cString: strerror(spawned)))
        }
        handle.started(pid: pid)

        let stdout = ShellOutputBuffer(limit: 1_000_000)
        let stderr = ShellOutputBuffer(limit: 1_000_000)
        let readers = DispatchGroup()
        let exited = ExitFlag()
        for (fd, buffer) in [(outFds[0], stdout), (errFds[0], stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffer.drain(fd: fd, exited: exited)
                close(fd)
                readers.leave()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        let status = ExitStatusBox()
        DispatchQueue.global(qos: .userInitiated).async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            status.value = raw
            exited.set()
            finished.signal()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            handle.signalGroup(SIGTERM)
            if finished.wait(timeout: .now() + 2) == .timedOut {
                handle.signalGroup(SIGKILL)
                finished.wait()
            }
        }
        // A background child can keep the pipes open after the command exits; the readers
        // give up shortly after exit rather than waiting on it.
        _ = readers.wait(timeout: .now() + 3)

        let raw = status.value
        let exitCode: Int
        if raw & 0x7f == 0 {
            exitCode = Int((raw >> 8) & 0xff)
        } else {
            exitCode = 128 + Int(raw & 0x7f)
        }
        return ShellResult(
            exitCode: exitCode,
            stdout: String(stdout.string.prefix(20_000)),
            stderr: String(stderr.string.prefix(8_000)),
            timedOut: timedOut
        )
    }

    public static func seatbeltProfile(home: URL, extraWriteRoots: [URL] = [], allowNetwork: Bool = false) -> String {
        let tmp = FileManager.default.temporaryDirectory
        func allowWrite(_ url: URL) -> String {
            let paths = seatbeltPaths(url)
            return paths.map { path in
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "(allow file-write* (subpath \"\(escaped)\"))"
            }.joined(separator: "\n")
        }
        let extra = extraWriteRoots.map { allowWrite($0) }.joined(separator: "\n")
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        \(secretReadDenials())
        \(allowNetwork ? "" : "(deny network*)")
        \(allowWrite(home))
        \(extra)
        (allow file-write* (subpath "/private/tmp"))
        (allow file-write* (subpath "/tmp"))
        \(allowWrite(tmp))
        (allow file-write-data (literal "/dev/null"))
        (allow file-ioctl)
        (allow sysctl-read)
        """
    }

    /// Paths under the real home that hold credentials, history or private mail/messages.
    static let secretReadPaths = [
        ".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker", "Library/Keychains",
        ".config/gh", ".config/op", ".npmrc", ".netrc", ".git-credentials", ".pypirc",
        ".zsh_history", ".zhistory", ".bash_history", ".python_history", ".node_repl_history",
        "Library/Mail", "Library/Messages", "Library/Cookies", "Library/Safari",
    ]

    /// Credential stores a shell command must not read, even though the profile
    /// otherwise allows reads. Resolved against the real user home, not the bot's.
    private static func secretReadDenials() -> String {
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let dirs = secretReadPaths
        return dirs.flatMap { seatbeltPaths(realHome.appendingPathComponent($0)) }
            .map { path in
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "(deny file-read* (subpath \"\(escaped)\"))"
            }
            .joined(separator: "\n")
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
    case shellLaunch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBotId: return "Invalid bot id"
        case .pathEscapes: return "Path escapes bot home"
        case .notFound(let p): return "Not found: \(p)"
        case .wrongType(let p): return "Wrong type: \(p)"
        case .hostDenied: return "That path is blocked (secrets). Ask the user to paste the file if they need it."
        case .shellLaunch(let why): return "Could not start the shell: \(why)"
        }
    }
}


/// Lets Stop (task cancellation) reach into a running shell command and kill its process group.
final class ShellProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    func started(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { signalGroup(SIGKILL) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        signalGroup(SIGKILL)
    }

    func signalGroup(_ signal: Int32) {
        lock.lock()
        let target = pid
        lock.unlock()
        if target > 0 { kill(-target, signal) }
    }
}

private final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int32 = 0
    var value: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return raw }
        set { lock.lock(); raw = newValue; lock.unlock() }
    }
}

private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Date?
    func set() { lock.lock(); at = .now; lock.unlock() }
    /// True once the process has been gone for `grace` seconds.
    func goneFor(_ grace: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at else { return false }
        return Date().timeIntervalSince(at) >= grace
    }
}

/// Collects up to `limit` bytes from a pipe, discarding the rest so the writer never blocks.
private final class ShellOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func drain(fd: Int32, exited: ExitFlag) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if exited.goneFor(1) { return }
                continue
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            if n == 0 { return }
            lock.lock()
            if data.count < limit { data.append(chunk, count: min(n, limit - data.count)) }
            lock.unlock()
        }
    }
}
