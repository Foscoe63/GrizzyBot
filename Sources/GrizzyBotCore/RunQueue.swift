import Foundation

/// What happens to a message sent while the bot is still working on the previous one.
public enum QueueMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Slip the message into the run in flight at the next tool boundary.
    case steer
    /// Hold messages until the run ends, then answer them together as one turn.
    case collect
    /// Hold messages until the run ends, then answer them one at a time.
    case followup

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .steer: return "Steer"
        case .collect: return "Collect"
        case .followup: return "Follow up"
        }
    }

    public var summary: String {
        switch self {
        case .steer: return "New messages reach the bot while it works, at its next step."
        case .collect: return "New messages wait, then are answered together once it finishes."
        case .followup: return "New messages wait, then are answered one at a time."
        }
    }
}

/// A message the person sent while a run was in flight. `messageId` is the thread
/// row already on screen, so it can be pulled and re-filed if the message ends up
/// starting a turn of its own.
public struct QueuedSend: Sendable, Equatable {
    public var messageId: String
    public var text: String
    public var imageJPEGBase64: String?

    public init(messageId: String, text: String, imageJPEGBase64: String? = nil) {
        self.messageId = messageId
        self.text = text
        self.imageJPEGBase64 = imageJPEGBase64
    }
}

/// Thread-safe mailbox the agent loop polls between steps. The loop runs off the
/// main actor, so this cannot live on the store.
public final class RunInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedSend] = []

    public init() {}

    public func push(_ item: QueuedSend) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    /// Removes and returns everything waiting.
    public func drain() -> [QueuedSend] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items.removeAll()
        return out
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty
    }
}

public enum QueuePlanner {
    /// The note the model sees when the person speaks up mid-run.
    public static func steerNote(_ messages: [String]) -> String {
        let cleaned = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        let body: String
        if cleaned.count == 1 {
            body = cleaned[0]
        } else {
            body = cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        return """
        [The person sent a new message while you were working. Take it into account and carry on — \
        change course if it says to, otherwise keep going.]
        \(body)
        """
    }

    /// Several held messages become one prompt.
    public static func merge(_ messages: [String]) -> String {
        let cleaned = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.count <= 1 { return cleaned.first ?? "" }
        return cleaned.joined(separator: "\n\n")
    }

    /// Splits the held messages into the turns that should actually run.
    /// `collect` answers them together; `steer` leftovers (the run ended before the
    /// loop looked) are treated the same way; `followup` keeps them apart.
    public static func turns(for held: [QueuedSend], mode: QueueMode) -> [[QueuedSend]] {
        guard !held.isEmpty else { return [] }
        switch mode {
        case .followup: return held.map { [$0] }
        case .steer, .collect: return [held]
        }
    }
}
