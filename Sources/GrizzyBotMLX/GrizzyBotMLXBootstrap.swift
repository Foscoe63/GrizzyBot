import Foundation
import GrizzyBotCore

/// Installs the MLX runtime behind the Local MLX provider.
///
/// GrizzyBotCore declares the `MLXTextGenerating` seam but links no MLX; the
/// app calls this once at launch so `MLXChatClient` finds a real generator.
/// Until it runs — and on a Mac that cannot run MLX at all — the provider
/// reports why it is unavailable instead of failing mid-turn.
public enum GrizzyBotMLXBootstrap {
    public static func install() {
        guard MLXProvider.isSupportedHardware else { return }
        MLXMetallibBootstrap.ensureColocated()
        MLXRuntime.register(MLXLocalGenerator.shared)
    }
}
