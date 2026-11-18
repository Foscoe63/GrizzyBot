import Foundation

/// A local-gateway caller waiting on a bot run: each streamed piece goes to `onDelta`, the final reply to
/// `onFinish` (once).
final class GatewayObserver: @unchecked Sendable {
    let onDelta: @Sendable (String) -> Void
    private let finish: @Sendable (String) -> Void
    private let lock = NSLock()
    private var finished = false

    init(onDelta: @escaping @Sendable (String) -> Void, onFinish: @escaping @Sendable (String) -> Void) {
        self.onDelta = onDelta
        self.finish = onFinish
    }

    func onFinish(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        finish(text)
    }
}
