import Foundation

/// Where a hand-over of the screen stands, so the next run knows what happened while the bot was waiting.
public struct TakeoverProgress: Sendable, Equatable {
    public var reason: String
    /// The person actually took the screen.
    public var taken: Bool = false

    public init(reason: String, taken: Bool = false) {
        self.reason = reason
        self.taken = taken
    }
}

public enum TakeoverResume {
    /// Said to the bot on its next turn after it asked for the screen.
    public static func note(_ progress: TakeoverProgress) -> String {
        if progress.taken {
            return "The person took over the screen and has handed it back. Whatever was on screen has changed: take a fresh screenshot before you click or type, and do not ask for the same takeover again for the step they just did."
        }
        return "Your takeover request was skipped: the person did not take the screen. Do not ask again for the same step. Carry on with what you can do without it, or say plainly what is blocked."
    }
}

extension AppStore {
    /// The note for a run that starts after a takeover request, once. Nil when none is outstanding.
    func takeoverResumeNote(botId: String) -> String? {
        guard let progress = takeoverProgress.removeValue(forKey: botId) else { return nil }
        return TakeoverResume.note(progress)
    }
}
