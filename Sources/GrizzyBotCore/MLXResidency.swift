import Foundation

/// Decides when the local model should give its GPU memory back: after sitting idle for a while, or
/// when macOS reports memory pressure. A model is never unloaded in the middle of a reply.
public final class MLXResidency: @unchecked Sendable {
    public static let shared = MLXResidency()
    public static let defaultIdleSeconds: TimeInterval = 600

    private let lock = NSLock()
    private var active = 0
    private var lastUsed: Date?
    private var loaded = false
    private var pressureSource: DispatchSourceMemoryPressure?
    private var idleTimer: DispatchSourceTimer?
    public var idleSeconds: TimeInterval = MLXResidency.defaultIdleSeconds
    /// Called when the model should be released.
    public var unloadHandler: (@Sendable () async -> Void)?

    public init() {}

    /// A generation is starting.
    public func begin(now: Date = .now) {
        lock.lock()
        active += 1
        loaded = true
        lastUsed = now
        lock.unlock()
    }

    /// A generation finished (or failed).
    public func end(now: Date = .now) {
        lock.lock()
        active = max(0, active - 1)
        lastUsed = now
        lock.unlock()
    }

    public func unloaded() {
        lock.lock(); loaded = false; lock.unlock()
    }

    /// True when a model is loaded, nothing is generating, and it has been idle long enough.
    public func shouldUnloadForIdle(now: Date = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard loaded, active == 0, idleSeconds > 0, let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) >= idleSeconds
    }

    /// Memory pressure frees the model as soon as nothing is generating.
    public func shouldUnloadForPressure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded && active == 0
    }

    /// Starts watching memory pressure and idleness. Safe to call more than once.
    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self, self.shouldUnloadForPressure() else { return }
            self.release()
        }
        source.resume()
        pressureSource = source
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, self.shouldUnloadForIdle() else { return }
            self.release()
        }
        timer.resume()
        idleTimer = timer
    }

    private func release() {
        guard let handler = unloadHandler else { return }
        unloaded()
        Task { await handler() }
    }
}
