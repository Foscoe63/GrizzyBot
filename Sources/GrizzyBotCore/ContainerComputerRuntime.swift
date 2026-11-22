import CoreGraphics
import Foundation
import ImageIO

/// Drives a bot's Private desktop: screenshots by `ffmpeg` and input by `xdotool`, both run inside the container.
public actor ContainerComputerRuntime: ComputerRuntime {
    private let desktop: PodmanDesktop
    private let readyAttempts: Int
    private let readyInterval: TimeInterval
    private var ready: Set<String> = []
    private var frames: [String: ComputerScreenFrame] = [:]
    private var urls: [String: String] = [:]
    private var problems: [String: String] = [:]

    public init(desktop: PodmanDesktop, readyAttempts: Int = 30, readyInterval: TimeInterval = 1) {
        self.desktop = desktop
        self.readyAttempts = readyAttempts
        self.readyInterval = readyInterval
    }

    // MARK: ComputerRuntime

    public func attach(botId: String, homeURL: URL) async {
        _ = homeURL
        _ = try? await ensureReady(botId)
    }

    public func prepareForDisplay(botId: String) async {
        _ = try? await ensureReady(botId)
    }

    public func snapshot(botId: String) async -> ComputerSnapshot? {
        do {
            let result = try await run(botId, XdotoolCommands.screenshot, timeout: 30)
            guard result.succeeded, !result.stdoutData.isEmpty, let size = Self.jpegSize(result.stdoutData) else {
                problems[botId] = "The Private desktop could not capture its screen. \(Self.trimmed(result.stderr))"
                return nil
            }
            problems[botId] = nil
            let frame = ComputerScreenFrame.square(size.width, size.height)
            frames[botId] = frame
            return ComputerSnapshot(jpeg: result.stdoutData, width: size.width, height: size.height,
                                    url: urls[botId] ?? "Private desktop", frame: frame)
        } catch {
            problems[botId] = error.localizedDescription
            return nil
        }
    }

    public func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult {
        do {
            let frame = try await currentFrame(botId)
            guard let command = XdotoolCommands.arguments(for: input, frame: frame) else {
                return ComputerActionResult(ok: false, summary: Self.rejected(input))
            }
            let result = try await run(botId, command, detached: input.kind == .open, timeout: 30)
            guard result.succeeded else {
                return ComputerActionResult(ok: false, summary: "\(Self.label(input)) failed: \(Self.trimmed(result.stderr))")
            }
            if input.kind == .open { urls[botId] = command.last }
            return ComputerActionResult(summary: Self.label(input), hit: ComputerHit(role: "private-desktop"))
        } catch {
            return ComputerActionResult(ok: false, summary: error.localizedDescription)
        }
    }

    public func lastFrame(botId: String) async -> ComputerScreenFrame? { frames[botId] }

    public func currentURL(botId: String) async -> String { urls[botId] ?? "" }

    public func sessionDescription(botId: String) async -> String {
        _ = botId
        return "private Linux desktop (logins last until the desktop is removed)"
    }

    public func unavailableReason(botId: String) async -> String? { problems[botId] }

    // MARK: Readiness

    /// Makes sure the container exists, runs, and its screen answers. Done once, then again only if it stops.
    private func ensureReady(_ botId: String) async throws {
        if ready.contains(botId) { return }
        do {
            let status = await desktop.status(botId: botId)
            if status.podmanPath == nil { throw PodmanDesktopError.podmanNotFound }
            if !status.machineRunning { throw PodmanDesktopError.machineNotRunning }
            // Building the image means a download of over 1 GB, so it is never done silently in the middle of a turn.
            if !status.imagePresent { throw PodmanDesktopError.imageNotBuilt }
            try await desktop.ensureRunning(botId: botId)
            try await desktop.waitUntilDisplayReady(botId: botId, attempts: readyAttempts, interval: readyInterval)
            ready.insert(botId)
            problems[botId] = nil
        } catch {
            problems[botId] = error.localizedDescription
            throw error
        }
    }

    /// One command in the desktop. If the container turns out to have stopped, it is brought back once and the command retried.
    private func run(_ botId: String, _ command: [String], detached: Bool = false, timeout: TimeInterval) async throws
        -> PodmanCommandResult {
        try await ensureReady(botId)
        let first = try await desktop.exec(botId: botId, command, detached: detached, timeout: timeout)
        guard !first.succeeded, Self.containerIsGone(first.stderr) else { return first }
        ready.remove(botId)
        try await ensureReady(botId)
        return try await desktop.exec(botId: botId, command, detached: detached, timeout: timeout)
    }

    /// Clicks need the screen's size; it is taken from a screenshot the first time.
    private func currentFrame(_ botId: String) async throws -> ComputerScreenFrame {
        if let frame = frames[botId] { return frame }
        guard await snapshot(botId: botId) != nil, let frame = frames[botId] else {
            throw ContainerRuntimeError.noScreen(problems[botId] ?? "The Private desktop has no screen yet.")
        }
        return frame
    }

    // MARK: Helpers

    static func containerIsGone(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("no such container") || text.contains("is not running") || text.contains("container state improper")
    }

    static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func trimmed(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    static func label(_ input: ComputerInput) -> String {
        switch input.kind {
        case .click: return "Clicked (\(Int(input.x)), \(Int(input.y)))"
        case .rightClick: return "Right-clicked (\(Int(input.x)), \(Int(input.y)))"
        case .doubleClick: return "Double-clicked (\(Int(input.x)), \(Int(input.y)))"
        case .scroll: return "Scrolled at (\(Int(input.x)), \(Int(input.y)))"
        case .type: return "Typed \(input.text.count) characters"
        case .key: return "Pressed \(input.text)"
        case .open: return "Opened \(input.text)"
        }
    }

    static func rejected(_ input: ComputerInput) -> String {
        switch input.kind {
        case .key: return "“\(input.text)” is not a key this desktop understands. Try names like Enter, Tab, Escape, ctrl+c, or F5."
        case .open: return "Only http and https pages can be opened on the Private desktop."
        case .type: return "There was no text to type."
        default: return "That position is not on the screen."
        }
    }
}

enum ContainerRuntimeError: LocalizedError {
    case noScreen(String)

    var errorDescription: String? {
        switch self {
        case .noScreen(let why): return why
        }
    }
}
