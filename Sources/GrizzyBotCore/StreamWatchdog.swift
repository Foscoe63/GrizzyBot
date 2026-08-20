import Foundation

/// Silence-on-the-wire, not a duration ceiling. 0 disables.
public struct StallClock: Sendable, Equatable {
    public var stallMs: Int
    public var lastEventMs: Int
    public var chunks: Int

    public init(stallMs: Int, lastEventMs: Int = 0, chunks: Int = 0) {
        self.stallMs = stallMs
        self.lastEventMs = lastEventMs
        self.chunks = chunks
    }

    public var enabled: Bool { stallMs > 0 }

    public mutating func touch(at nowMs: Int) {
        lastEventMs = nowMs
        chunks += 1
    }

    public func silentForMs(nowMs: Int) -> Int {
        max(0, nowMs - lastEventMs)
    }

    public func isStalled(nowMs: Int) -> Bool {
        enabled && silentForMs(nowMs: nowMs) >= stallMs
    }

    public static func words(ms: Int) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        let seconds = ms / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

public struct StreamStallError: Error, LocalizedError, Equatable {
    public var silentForMs: Int
    public var chunks: Int

    public init(silentForMs: Int, chunks: Int) {
        self.silentForMs = silentForMs
        self.chunks = chunks
    }

    public var errorDescription: String? {
        "The model stopped responding. Nothing arrived from it for \(StallClock.words(ms: silentForMs))."
    }

    public var code: String { "AGENT_STREAM_STALLED" }
}

/// Times silence on a live stream. Touch from the reader; the watchdog task polls.
public actor StallMonitor {
    private var clock: StallClock
    private let started: ContinuousClock.Instant

    public init(stallMs: Int) {
        self.clock = StallClock(stallMs: stallMs)
        self.started = .now
    }

    public var enabled: Bool { clock.enabled }

    public func touch() {
        clock.touch(at: nowMs())
    }

    public func isStalled() -> Bool {
        clock.isStalled(nowMs: nowMs())
    }

    public func snapshot() -> (silentForMs: Int, chunks: Int, stalled: Bool) {
        let now = nowMs()
        return (clock.silentForMs(nowMs: now), clock.chunks, clock.isStalled(nowMs: now))
    }

    public func watchUntilStall() async throws {
        guard clock.enabled else {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return
        }
        let sweep = UInt64(min(1_000, max(50, clock.stallMs / 4))) * 1_000_000
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: sweep)
            if clock.isStalled(nowMs: nowMs()) {
                throw StreamStallError(silentForMs: clock.stallMs, chunks: clock.chunks)
            }
        }
    }

    private func nowMs() -> Int {
        let elapsed = ContinuousClock.now - started
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
