import Foundation

/// Chooses the generator backing `MLXChatClient`.
///
/// The real implementation lives behind `canImport(MLXLLM)`, so GrizzyBotCore
/// still builds — and its tests still run — in a configuration that does not
/// link the MLX runtime. When MLX is absent the provider stays visible in the
/// picker but says plainly why it cannot run, instead of failing obscurely
/// deep in a chat turn.
public enum MLXRuntime {
    /// Overridden by tests to drive `MLXChatClient` without a real model.
    nonisolated(unsafe) public static var generatorOverride: (any MLXTextGenerating)?

    public static var isAvailable: Bool {
        #if canImport(MLXLLM)
        return MLXProvider.isSupportedHardware
        #else
        return false
        #endif
    }

    /// Why Local MLX cannot run here, or `nil` when it can.
    public static var unavailableReason: String? {
        if !MLXProvider.isSupportedHardware {
            return MLXProvider.unsupportedHardwareMessage
        }
        #if canImport(MLXLLM)
        return nil
        #else
        return "This build of GrizzyBot was compiled without the MLX runtime."
        #endif
    }

    public static func makeGenerator() -> any MLXTextGenerating {
        if let generatorOverride { return generatorOverride }
        #if canImport(MLXLLM)
        return MLXLocalGenerator.shared
        #else
        return MLXUnavailableGenerator(
            reason: unavailableReason
                ?? "The MLX runtime is not available in this build of GrizzyBot."
        )
        #endif
    }
}
