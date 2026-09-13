import CoreServices
import Foundation

/// One folder watcher — FSEvents → bot run (GrizzyClaw-inspired).
public struct FolderWatcherRecord: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var watchPath: String
    public var recursive: Bool
    /// `fast`, `balanced`, or `patient`
    public var responsiveness: String
    public var enabled: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxConvergence: Int
    /// Bot that runs when the folder changes.
    public var botId: String?
    public var createdAt: String
    public var lastTriggeredAt: String?
    public var lastError: String?

    public static let defaultExcludeGlobs: [String] = [
        ".git/**",
        "**/node_modules/**",
        "**/.venv/**",
        "**/__pycache__/**",
    ]

    public init(
        id: String = UUID().uuidString,
        name: String = "Untitled watcher",
        instructions: String = "",
        watchPath: String = "",
        recursive: Bool = true,
        responsiveness: String = "balanced",
        enabled: Bool = true,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = FolderWatcherRecord.defaultExcludeGlobs,
        maxConvergence: Int = 5,
        botId: String? = nil,
        createdAt: String = FolderWatcherRecord.isoNow(),
        lastTriggeredAt: String? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.watchPath = watchPath
        self.recursive = recursive
        self.responsiveness = responsiveness
        self.enabled = enabled
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxConvergence = maxConvergence
        self.botId = botId
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id, name, instructions
        case watchPath = "watch_path"
        case recursive, responsiveness, enabled
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
        case maxConvergence = "max_convergence"
        case botId = "bot_id"
        case createdAt = "created_at"
        case lastTriggeredAt = "last_triggered_at"
        case lastError = "last_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled watcher"
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        watchPath = try c.decodeIfPresent(String.self, forKey: .watchPath) ?? ""
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        responsiveness = try c.decodeIfPresent(String.self, forKey: .responsiveness) ?? "balanced"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? Self.defaultExcludeGlobs
        maxConvergence = try c.decodeIfPresent(Int.self, forKey: .maxConvergence) ?? 5
        botId = try c.decodeIfPresent(String.self, forKey: .botId)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? Self.isoNow()
        lastTriggeredAt = try c.decodeIfPresent(String.self, forKey: .lastTriggeredAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    public static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    public static func makeNew() -> FolderWatcherRecord {
        FolderWatcherRecord()
    }
}

/// Skip a watcher fire when the bot is busy or this watcher is still absorbing its own writes.
public enum FolderWatcherFirePolicy {
    public static func skipReason(botBusy: Bool, suppressed: Bool, manual: Bool) -> String? {
        if botBusy { return "Skipped: bot is already running." }
        if !manual, suppressed { return "Skipped: watcher is cooling down." }
        return nil
    }
}

/// Drops FSEvents produced by an in-flight organize pass, so a watcher that
/// moves files does not retrigger itself.
///
/// One of these belongs to one `FolderWatcherService`. It used to be a global,
/// which meant two services — two tests, or two workspaces — shared suppression
/// state for watcher ids that had nothing to do with each other.
///
/// Synchronous and lock-protected rather than actor state, because the store
/// reads it while deciding whether to fire, and that decision is not async.
public final class FolderWatcherSuppression: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var ids: Set<String> = []
    private var generation: [String: UInt64] = [:]

    public func isSuppressed(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }

    @discardableResult
    public func suppress(_ id: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
        let next = (generation[id] ?? 0) &+ 1
        generation[id] = next
        return next
    }

    public func currentGeneration(_ id: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation[id] ?? 0
    }

    public func release(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.remove(id)
    }
}

public enum FolderWatcherGlobMatching {
    public static func matches(relativePath: String, includeGlobs: [String], excludeGlobs: [String]) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        for pattern in excludeGlobs where globMatch(pattern: pattern, path: normalized) {
            return false
        }
        if includeGlobs.isEmpty { return true }
        for pattern in includeGlobs where globMatch(pattern: pattern, path: normalized) {
            return true
        }
        return false
    }

    public static func debounceSeconds(for responsiveness: String) -> TimeInterval {
        switch responsiveness.lowercased() {
        case "fast": return 0.5
        case "patient": return 5.0
        default: return 2.0
        }
    }

    public static func anyChangedPathMatches(
        changedPaths: [String],
        watchRoot: String,
        includeGlobs: [String],
        excludeGlobs: [String]
    ) -> Bool {
        let root = (watchRoot as NSString).standardizingPath
        for path in changedPaths {
            let rel = relativePath(fullPath: path, watchRoot: root)
            if matches(relativePath: rel, includeGlobs: includeGlobs, excludeGlobs: excludeGlobs) {
                return true
            }
        }
        return false
    }

    public static func relativePath(fullPath: String, watchRoot: String) -> String {
        let full = (fullPath as NSString).standardizingPath
        let prefix = watchRoot.hasSuffix("/") ? watchRoot : watchRoot + "/"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        if full == watchRoot { return "" }
        return (fullPath as NSString).lastPathComponent
    }

    private static func globMatch(pattern: String, path: String) -> Bool {
        let p = pattern.replacingOccurrences(of: "\\", with: "/")
        if p.hasSuffix("/**") {
            let prefix = String(p.dropLast(3))
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        let regex = globToRegex(p)
        return path.range(of: regex, options: .regularExpression) != nil
            || (path as NSString).lastPathComponent.range(of: regex, options: .regularExpression) != nil
    }

    private static func globToRegex(_ glob: String) -> String {
        var out = "^"
        for ch in glob {
            switch ch {
            case "*": out += ".*"
            case "?": out += "."
            case ".": out += "\\."
            default: out.append(ch)
            }
        }
        out += "$"
        return out
    }
}

public enum FolderWatcherPromptBuilder {
    public static func userMessage(
        watcher: FolderWatcherRecord,
        changedPaths: [String],
        manual: Bool
    ) -> String {
        var parts: [String] = []
        let name = watcher.name.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(name.isEmpty ? "[Folder watcher]" : "[Folder watcher: \(name)]")
        let path = (watcher.watchPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            parts.append("Watch path: \(path)")
        }
        let uniquePaths = dedupe(
            changedPaths.map { ($0 as NSString).expandingTildeInPath }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        if uniquePaths.isEmpty {
            parts.append(
                manual
                    ? "Trigger: manual run once (no specific file changes). Act on the watch path above."
                    : "Trigger: filesystem changes detected. Act on the watch path above."
            )
        } else {
            parts.append("Changed paths:")
            for p in uniquePaths.prefix(40) {
                parts.append("- \(p)")
            }
            if uniquePaths.count > 40 {
                parts.append("- …and \(uniquePaths.count - 40) more")
            }
        }
        if !path.isEmpty {
            parts.append("")
            parts.append(
                "This folder job applies to whichever bot is running. Do one organize pass now on the watch path using list_files then move_file (or shell mv — writes in this folder are allowed). Do not write organizer scripts, file-watcher.py, or SKILL.md. Do not load the browser skill. Do not loop or wait for more files. Relative list_files / read_file / write_file / edit_file / move_file / delete_file resolve to the watch path — not that bot's home, knowledge vault, or skills library."
            )
        }
        let instructions = watcher.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            parts.append("")
            parts.append("Instructions:")
            parts.append(instructions)
        }
        return parts.joined(separator: "\n")
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }
}

public enum FolderWatcherPersistence {
    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("watchers", isDirectory: true)
    }

    public static func loadAll(root: URL) throws -> [FolderWatcherRecord] {
        let dir = directory(root: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.compactMap { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FolderWatcherRecord.self, from: data)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func save(_ watcher: FolderWatcherRecord, root: URL) throws {
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(watcher.id).json")
        let data = try JSONEncoder().encode(watcher)
        try data.write(to: url, options: .atomic)
    }

    public static func delete(id: String, root: URL) throws {
        let url = directory(root: root).appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public protocol FolderWatcherRunning: Sendable {
    func runWatcher(_ watcher: FolderWatcherRecord, changedPaths: [String], manual: Bool) async throws -> String
}

/// Native FSEvents folder watcher runtime.
public actor FolderWatcherService {
    /// Suppression this service consults, shared with whoever owns it — the
    /// store reads the same object synchronously when deciding to fire.
    public nonisolated let suppression: FolderWatcherSuppression

    private var runner: (any FolderWatcherRunning)?
    private var persistenceRoot: URL?
    private var reloadTask: Task<Void, Never>?
    private var streams: [String: FSEventStreamRef] = [:]
    private var pendingTimers: [String: Task<Void, Never>] = [:]
    private var convergenceCounts: [String: Int] = [:]
    private var pendingChangedPaths: [String: [String]] = [:]

    public init(suppression: FolderWatcherSuppression = FolderWatcherSuppression()) {
        self.suppression = suppression
    }

    public func configure(root: URL, runner: any FolderWatcherRunning) {
        persistenceRoot = root
        self.runner = runner
    }

    public func start() {
        if reloadTask == nil {
            reloadTask = Task { await self.reloadLoop() }
        }
        Task { try? await reloadWatchers() }
    }

    public func reloadNow() async {
        try? await reloadWatchers()
    }

    public func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        stopAllStreams()
    }

    public func runWatcherNow(id: String) async throws -> String {
        guard let root = persistenceRoot else {
            throw FolderWatcherError.notConfigured
        }
        let watchers = try FolderWatcherPersistence.loadAll(root: root)
        guard let watcher = watchers.first(where: { $0.id == id }) else {
            throw FolderWatcherError.notFound
        }
        return try await executeWatcher(watcher, manual: true)
    }

    private func reloadLoop() async {
        while !Task.isCancelled {
            do {
                try await reloadWatchers()
            } catch {
                // Keep looping; next tick retries.
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private func reloadWatchers() async throws {
        stopAllStreams()
        guard let root = persistenceRoot else { return }
        let watchers = try FolderWatcherPersistence.loadAll(root: root).filter(\.enabled)
        for watcher in watchers {
            let path = (watcher.watchPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            startStream(for: watcher, path: path)
        }
    }

    private func stopAllStreams() {
        for (_, stream) in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
        for (_, t) in pendingTimers { t.cancel() }
        pendingTimers.removeAll()
        convergenceCounts.removeAll()
        pendingChangedPaths.removeAll()
    }

    private func startStream(for watcher: FolderWatcherRecord, path: String) {
        let id = watcher.id
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(WatcherCallbackBox(watcherId: id, service: self)).toOpaque(),
            retain: nil,
            release: { info in
                Unmanaged<WatcherCallbackBox>.fromOpaque(info!).release()
            },
            copyDescription: nil
        )
        let paths = [path] as CFArray
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        )
        if watcher.recursive {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        }
        guard let stream = FSEventStreamCreate(
            nil,
            grizzyBotFolderWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        streams[id] = stream
    }

    public func dropPending(watcherId: String) {
        pendingTimers[watcherId]?.cancel()
        pendingTimers[watcherId] = nil
        pendingChangedPaths[watcherId] = nil
        convergenceCounts[watcherId] = 0
    }

    fileprivate func handleFSEvent(watcherId: String, changedPaths: [String]) {
        if suppression.isSuppressed(watcherId) {
            dropPending(watcherId: watcherId)
            return
        }
        guard let root = persistenceRoot,
              let watcher = try? FolderWatcherPersistence.loadAll(root: root).first(where: { $0.id == watcherId })
        else { return }
        let watchRoot = (watcher.watchPath as NSString).expandingTildeInPath
        guard FolderWatcherGlobMatching.anyChangedPathMatches(
            changedPaths: changedPaths,
            watchRoot: watchRoot,
            includeGlobs: watcher.includeGlobs,
            excludeGlobs: watcher.excludeGlobs
        ) else { return }

        var accumulated = pendingChangedPaths[watcherId] ?? []
        accumulated.append(contentsOf: changedPaths)
        pendingChangedPaths[watcherId] = dedupe(accumulated)

        pendingTimers[watcherId]?.cancel()
        pendingTimers[watcherId] = Task {
            let delay = FolderWatcherGlobMatching.debounceSeconds(for: watcher.responsiveness)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.scheduleConvergenceCheck(watcher: watcher)
        }
    }

    private func scheduleConvergenceCheck(watcher: FolderWatcherRecord) async {
        let id = watcher.id
        if suppression.isSuppressed(id) {
            dropPending(watcherId: id)
            return
        }
        let generation = suppression.currentGeneration(id)
        let count = (convergenceCounts[id] ?? 0) + 1
        convergenceCounts[id] = count
        if count < max(1, watcher.maxConvergence) {
            pendingTimers[id] = Task {
                let delay = FolderWatcherGlobMatching.debounceSeconds(for: watcher.responsiveness)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.scheduleConvergenceCheck(watcher: watcher)
            }
            return
        }
        convergenceCounts[id] = 0
        let paths = pendingChangedPaths.removeValue(forKey: id) ?? []
        if suppression.isSuppressed(id)
            || suppression.currentGeneration(id) != generation
        {
            return
        }
        _ = try? await executeWatcher(watcher, manual: false, changedPaths: paths)
    }

    private func executeWatcher(
        _ watcher: FolderWatcherRecord,
        manual: Bool,
        changedPaths: [String] = []
    ) async throws -> String {
        guard let runner, let root = persistenceRoot else {
            throw FolderWatcherError.notConfigured
        }
        do {
            let result = try await runner.runWatcher(watcher, changedPaths: changedPaths, manual: manual)
            var updated = watcher
            if result.hasPrefix("Triggered") {
                updated.lastTriggeredAt = FolderWatcherRecord.isoNow()
                updated.lastError = nil
                try? FolderWatcherPersistence.save(updated, root: root)
            }
            return result
        } catch {
            var updated = watcher
            updated.lastError = error.localizedDescription
            try? FolderWatcherPersistence.save(updated, root: root)
            throw error
        }
    }

    private func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }
}

public enum FolderWatcherError: LocalizedError, Sendable {
    case notConfigured
    case notFound
    case emptyPath

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Folder watchers are not configured."
        case .notFound: return "Watcher not found."
        case .emptyPath: return "Choose a folder to watch."
        }
    }
}

/// Bridges FSEvents into AppStore on the main actor.
public struct StoreFolderWatcherRunner: FolderWatcherRunning {
    private let handler: @Sendable (FolderWatcherRecord, [String], Bool) async -> String

    public init(handler: @escaping @Sendable (FolderWatcherRecord, [String], Bool) async -> String) {
        self.handler = handler
    }

    public func runWatcher(
        _ watcher: FolderWatcherRecord,
        changedPaths: [String],
        manual: Bool
    ) async throws -> String {
        await handler(watcher, changedPaths, manual)
    }
}

private final class WatcherCallbackBox: @unchecked Sendable {
    let watcherId: String
    /// The service that opened this stream. Carried through the FSEvents info
    /// pointer so an event reaches the instance that asked for it — with a
    /// global, every stream in the process fed the same one.
    let service: FolderWatcherService
    init(watcherId: String, service: FolderWatcherService) {
        self.watcherId = watcherId
        self.service = service
    }
}

private func grizzyBotFolderWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let box = Unmanaged<WatcherCallbackBox>.fromOpaque(info).takeUnretainedValue()
    let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    Task { [service = box.service, watcherId = box.watcherId] in
        await service.handleFSEvent(watcherId: watcherId, changedPaths: pathsArray)
    }
}
