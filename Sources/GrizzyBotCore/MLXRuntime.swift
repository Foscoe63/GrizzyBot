import Foundation

/// Holds the generator that backs `MLXChatClient`.
///
/// The MLX runtime lives in its own target (`GrizzyBotMLX`) so GrizzyBotCore —
/// and the test suite — stay free of the MLX and tokenizer dependencies. The
/// app installs the real generator at launch with `register(_:)`; until then,
/// and on a machine that cannot run MLX, the provider stays visible in the
/// picker but says plainly why it cannot run rather than failing obscurely
/// deep in a chat turn.
public enum MLXRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: (any MLXTextGenerating)?

    /// Install the MLX-backed generator. Called once at app launch.
    public static func register(_ generator: any MLXTextGenerating) {
        lock.lock()
        installed = generator
        lock.unlock()
    }

    /// Tests use this to drive `MLXChatClient` without a real model.
    public static func reset() {
        lock.lock()
        installed = nil
        lock.unlock()
    }

    public static var isAvailable: Bool {
        guard MLXProvider.isSupportedHardware else { return false }
        lock.lock()
        defer { lock.unlock() }
        return installed != nil
    }

    /// Why Local MLX cannot run here, or `nil` when it can.
    public static var unavailableReason: String? {
        guard MLXProvider.isSupportedHardware else {
            return MLXProvider.unsupportedHardwareMessage
        }
        return isAvailable ? nil : "The MLX runtime is not available in this build of GrizzyBot."
    }

    public static func makeGenerator() -> any MLXTextGenerating {
        lock.lock()
        let generator = installed
        lock.unlock()
        return generator
            ?? MLXUnavailableGenerator(
                reason: unavailableReason
                    ?? "The MLX runtime is not available in this build of GrizzyBot."
            )
    }
}
