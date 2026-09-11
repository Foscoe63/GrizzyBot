import Foundation

/// Live state of one model download.
public struct MLXDownloadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case resolving
        case downloading
        case finishing
        case completed
        case failed(String)
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .resolving, .downloading, .finishing: return false
            }
        }
    }

    public var repoId: String
    public var phase: Phase
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var filesCompleted: Int
    public var filesTotal: Int
    /// The file currently transferring, for the status line.
    public var currentFile: String?

    public init(
        repoId: String,
        phase: Phase = .resolving,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        filesCompleted: Int = 0,
        filesTotal: Int = 0,
        currentFile: String? = nil
    ) {
        self.repoId = repoId
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.currentFile = currentFile
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public var statusText: String {
        switch phase {
        case .resolving: return "Resolving files…"
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(done) of \(total) · \(filesCompleted)/\(filesTotal) files"
        case .finishing: return "Verifying…"
        case .completed: return "Downloaded"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

/// Downloads a Hugging Face MLX model bundle into GrizzyBot's models folder.
///
/// Files are written to `<models>/<org>/<repo>/…` through a `.part` sidecar and
/// renamed on completion, so an interrupted download resumes with an HTTP
/// `Range` request instead of starting over, and a half-written weight file is
/// never mistaken for a complete bundle by the locator.
public actor MLXModelDownloader {
    public static let shared = MLXModelDownloader()

    /// How many files transfer at once. Weight shards are large and the Hub
    /// throttles aggressive parallelism, so this stays small.
    private static let maxConcurrentFiles = 3

    private var tasks: [String: Task<URL, Error>] = [:]
    private var progress: [String: MLXDownloadProgress] = [:]
    private var observers: [UUID: @Sendable (MLXDownloadProgress) -> Void] = [:]

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            // A weight shard on a slow link can legitimately take a long time.
            config.timeoutIntervalForResource = 60 * 60 * 6
            config.httpMaximumConnectionsPerHost = Self.maxConcurrentFiles
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Observation

    /// Observe every progress update. Returns a token for `removeObserver`.
    public func addObserver(_ observer: @escaping @Sendable (MLXDownloadProgress) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        for value in progress.values { observer(value) }
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    public func activeDownloads() -> [MLXDownloadProgress] {
        progress.values.filter { !$0.phase.isTerminal }.sorted { $0.repoId < $1.repoId }
    }

    public func progress(for repoId: String) -> MLXDownloadProgress? {
        progress[repoId]
    }

    // MARK: - Control

    /// Start (or join) a download of `repoId`. Returns the bundle directory.
    @discardableResult
    public func download(repoId: String, token: String? = nil) async throws -> URL {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("/") else {
            throw MLXHubError.message("Expected a Hugging Face repo id like `mlx-community/Qwen3-4B-4bit`.")
        }
        if let existing = tasks[trimmed] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw MLXHubError.message("Downloader went away.") }
            return try await self.run(repoId: trimmed, token: token)
        }
        tasks[trimmed] = task

        do {
            let url = try await task.value
            tasks[trimmed] = nil
            return url
        } catch {
            tasks[trimmed] = nil
            if error is CancellationError {
                update(repoId: trimmed) { $0.phase = .cancelled }
            } else {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                update(repoId: trimmed) { $0.phase = .failed(message) }
            }
            throw error
        }
    }

    public func cancel(repoId: String) {
        tasks[repoId]?.cancel()
        tasks[repoId] = nil
        update(repoId: repoId) { $0.phase = .cancelled }
    }

    /// Delete a downloaded bundle from GrizzyBot's models folder. Only paths
    /// inside that folder are removable — a model discovered in the Hugging
    /// Face cache or LM Studio belongs to that app, not to us.
    public func removeDownloaded(repoId: String) throws {
        let root = MLXModelLocator.downloadsDirectory()
        guard let dir = MLXHuggingFaceService.destinationURL(forRemotePath: repoId, under: root),
              MLXModelBundle.isContained(dir, in: root)
        else {
            throw MLXHubError.message("That model is not in GrizzyBot's downloads folder.")
        }
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
        progress[repoId] = nil
        notifyAll()
    }

    // MARK: - Work

    private func run(repoId: String, token: String?) async throws -> URL {
        update(repoId: repoId) {
            $0 = MLXDownloadProgress(repoId: repoId, phase: .resolving)
        }

        let allFiles = try await MLXHuggingFaceService.shared.allFiles(repoId: repoId, token: token)
        guard MLXHuggingFaceService.filesFormLoadableBundle(allFiles) else {
            throw MLXHubError.message(
                "\(repoId) is not a complete MLX bundle — it needs config.json, a tokenizer, and .safetensors weights."
            )
        }
        let files = MLXHuggingFaceService.filterDownloadable(allFiles)
        guard !files.isEmpty else {
            throw MLXHubError.message("\(repoId) has no downloadable model files.")
        }

        let root = MLXModelLocator.downloadsDirectory()
        guard let destination = MLXHuggingFaceService.destinationURL(forRemotePath: repoId, under: root) else {
            throw MLXHubError.message("That repo id cannot be mapped to a safe folder name.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = files.reduce(0) { $0 + $1.size }
        // Bytes already on disk from an earlier interrupted run, so a resumed
        // download does not restart the progress bar at zero.
        let alreadyOnDisk = files.reduce(Int64(0)) { sum, file in
            guard let url = MLXHuggingFaceService.destinationURL(forRemotePath: file.path, under: destination),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return sum }
            return sum + Int64(size)
        }

        update(repoId: repoId) {
            $0.phase = .downloading
            $0.totalBytes = total
            $0.completedBytes = min(alreadyOnDisk, total)
            $0.filesTotal = files.count
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = files.makeIterator()
            var inFlight = 0

            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.fetch(file: file, repoId: repoId, into: destination, token: token)
                }
                inFlight += 1
                return true
            }

            while inFlight < Self.maxConcurrentFiles, addNext() {}
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                if addNext() { inFlight += 1 }
            }
        }

        update(repoId: repoId) { $0.phase = .finishing }

        // The bundle must pass the same validation the locator applies, or the
        // model would appear in the folder yet never load.
        let diagnostic = MLXModelBundle.diagnostic(at: destination, root: root)
        guard diagnostic.isValid else {
            throw MLXHubError.message(
                diagnostic.detail ?? "The downloaded folder is not a complete MLX bundle."
            )
        }

        update(repoId: repoId) {
            $0.phase = .completed
            $0.completedBytes = $0.totalBytes
            $0.filesCompleted = $0.filesTotal
            $0.currentFile = nil
        }
        return destination
    }

    /// Download one file, resuming from a `.part` sidecar when one exists.
    private func fetch(file: MLXHubFile, repoId: String, into destination: URL, token: String?) async throws {
        try Task.checkCancellation()

        guard let target = MLXHuggingFaceService.destinationURL(forRemotePath: file.path, under: destination),
              let remote = MLXHuggingFaceService.fileURL(repoId: repoId, path: file.path)
        else {
            throw MLXHubError.message("Refusing to write \(file.path) — it escapes the model folder.")
        }

        let fm = FileManager.default
        // A complete file from an earlier run is kept as-is.
        if let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           file.size > 0, Int64(size) == file.size {
            update(repoId: repoId) { $0.filesCompleted += 1 }
            return
        }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = target.appendingPathExtension("part")
        let resumeFrom = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        update(repoId: repoId) { $0.currentFile = file.path }

        var request = URLRequest(url: remote)
        request.setValue("GrizzyBot", forHTTPHeaderField: "User-Agent")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MLXHubError.message("Hugging Face returned an unexpected response for \(file.path).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MLXHubError.http(http.statusCode, file.path)
        }
        // A server that ignored the Range header sends 200 with the whole file;
        // appending to the sidecar would corrupt it, so start clean.
        let appending = resumeFrom > 0 && http.statusCode == 206
        if !appending, fm.fileExists(atPath: part.path) {
            try? fm.removeItem(at: part)
        }
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        if appending {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
            update(repoId: repoId) { $0.completedBytes = max(0, $0.completedBytes - resumeFrom) }
        }

        // Buffer so the write syscall and the progress update run once per
        // chunk rather than once per byte.
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var sinceLastReport = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                sinceLastReport += buffer.count
                buffer.removeAll(keepingCapacity: true)
                let delta = Int64(sinceLastReport)
                sinceLastReport = 0
                update(repoId: repoId) { $0.completedBytes += delta }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            let delta = Int64(buffer.count)
            update(repoId: repoId) { $0.completedBytes += delta }
        }
        try handle.close()

        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        try fm.moveItem(at: part, to: target)
        update(repoId: repoId) { $0.filesCompleted += 1 }
    }

    // MARK: - Progress plumbing

    private func update(repoId: String, _ mutate: (inout MLXDownloadProgress) -> Void) {
        var value = progress[repoId] ?? MLXDownloadProgress(repoId: repoId)
        mutate(&value)
        progress[repoId] = value
        for observer in observers.values { observer(value) }
    }

    private func notifyAll() {
        for value in progress.values {
            for observer in observers.values { observer(value) }
        }
    }
}
