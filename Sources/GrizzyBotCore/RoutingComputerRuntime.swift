import Foundation

/// Sends each bot's computer calls to the runtime for its mode: the Private desktop's container, or the app's own
/// browser and This Mac runtime for every other mode. A bot whose mode was never announced uses the app's runtime.
public actor RoutingComputerRuntime: ComputerRuntime {
    private let primary: any ComputerRuntime
    private let privateDesktop: any ComputerRuntime
    private var modes: [String: ComputerMode] = [:]

    public init(primary: any ComputerRuntime, privateDesktop: any ComputerRuntime) {
        self.primary = primary
        self.privateDesktop = privateDesktop
    }

    private func runtime(for botId: String) -> any ComputerRuntime {
        modes[botId] == .privateDesktop ? privateDesktop : primary
    }

    public func setMode(botId: String, mode: ComputerMode) async { modes[botId] = mode }

    public func attach(botId: String, homeURL: URL) async { await runtime(for: botId).attach(botId: botId, homeURL: homeURL) }
    public func snapshot(botId: String) async -> ComputerSnapshot? { await runtime(for: botId).snapshot(botId: botId) }
    public func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult {
        await runtime(for: botId).send(input, botId: botId)
    }
    public func lastFrame(botId: String) async -> ComputerScreenFrame? { await runtime(for: botId).lastFrame(botId: botId) }
    public func currentURL(botId: String) async -> String { await runtime(for: botId).currentURL(botId: botId) }
    public func setSession(botId: String, thisMac: Bool, persistent: Bool) async {
        await runtime(for: botId).setSession(botId: botId, thisMac: thisMac, persistent: persistent)
    }
    public func sessionDescription(botId: String) async -> String { await runtime(for: botId).sessionDescription(botId: botId) }
    public func prepareForDisplay(botId: String) async { await runtime(for: botId).prepareForDisplay(botId: botId) }
    public func unavailableReason(botId: String) async -> String? { await runtime(for: botId).unavailableReason(botId: botId) }
}
