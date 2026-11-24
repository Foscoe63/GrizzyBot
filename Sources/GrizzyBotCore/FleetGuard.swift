import CryptoKit
import Foundation

/// Rules for a bot that manages other bots. Each refusal says what to do next.
public enum FleetGuard {
    public static let maxInstructionsChars = 20_000
    /// An approval card must show the whole change; a longer one is refused rather than shown cut off.
    public static let maxShownChars = 3_000

    /// A short version stamp of a bot's instructions. An edit must quote the stamp it read.
    public static func version(of instructions: String) -> String {
        SHA256.hash(data: Data(instructions.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public enum Refusal: Equatable, Sendable {
        case notOwnerStarted
        case tooLong(Int)
        case versionMissing(current: String)
        case stale(current: String)
        case notShownWhole
        case nothingToChange

        public var message: String {
            switch self {
            case .notOwnerStarted:
                return "Management tools only work in a run the owner started. This run was started by another bot, a routine or a webhook, or it read outside content, so changing a bot's instructions is left to the owner."
            case .tooLong(let n):
                return "Instructions are limited to \(FleetGuard.maxInstructionsChars) characters; this one is \(n). Shorten it."
            case .versionMissing(let current):
                return "Read the bot's current instructions first and pass expected_version. The current version is \(current)."
            case .stale(let current):
                return "The instructions changed since you read them (current version \(current)). Read them again and redo the edit."
            case .notShownWhole:
                return "The change is too long to show the owner whole, so it was not made. Make a smaller change."
            case .nothingToChange:
                return "That is already what the instructions say."
            }
        }
    }

    /// Checks an instruction edit. Returns nil when it may go to the owner for approval.
    public static func check(
        current: String,
        proposed: String,
        expectedVersion: String,
        ownerStarted: Bool,
        tainted: Bool
    ) -> Refusal? {
        guard ownerStarted, !tainted else { return .notOwnerStarted }
        if proposed.count > maxInstructionsChars { return .tooLong(proposed.count) }
        let now = version(of: current)
        if expectedVersion.isEmpty { return .versionMissing(current: now) }
        if expectedVersion != now { return .stale(current: now) }
        if proposed == current { return .nothingToChange }
        if proposed.count > maxShownChars { return .notShownWhole }
        return nil
    }

    /// What the approval card shows: the bot and the new text, in full.
    public static func approvalDetail(botName: String, proposed: String) -> String {
        "Replace \(botName)'s instructions with:\n\(proposed)"
    }
}
