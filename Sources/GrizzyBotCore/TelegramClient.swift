import Foundation

// MARK: - Settings

/// Telegram as a way to reach your bots from a phone. The bot token lives in the Keychain
/// (`connectionSecrets["telegram:token"]`), never here.
public struct TelegramSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Private chats that have been paired. Anyone else is ignored (after being told how to pair).
    public var allowedChatIds: [Int64]
    /// Which bot each chat is currently talking to (chat id as a string → bot id).
    public var chatBots: [String: String]
    /// Bot that answers a chat that has not picked one. Falls back to the chief of staff.
    public var defaultBotId: String?
    /// Send a short note to paired chats when a routine finishes.
    public var notifyRoutines: Bool
    /// Filled in once the token has been checked.
    public var botUsername: String?

    public static let `default` = TelegramSettings()

    public init(
        enabled: Bool = false,
        allowedChatIds: [Int64] = [],
        chatBots: [String: String] = [:],
        defaultBotId: String? = nil,
        notifyRoutines: Bool = true,
        botUsername: String? = nil
    ) {
        self.enabled = enabled
        self.allowedChatIds = allowedChatIds
        self.chatBots = chatBots
        self.defaultBotId = defaultBotId
        self.notifyRoutines = notifyRoutines
        self.botUsername = botUsername
    }

    enum CodingKeys: String, CodingKey {
        case enabled, allowedChatIds, chatBots, defaultBotId, notifyRoutines, botUsername
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowedChatIds = try c.decodeIfPresent([Int64].self, forKey: .allowedChatIds) ?? []
        chatBots = try c.decodeIfPresent([String: String].self, forKey: .chatBots) ?? [:]
        defaultBotId = try c.decodeIfPresent(String.self, forKey: .defaultBotId)
        notifyRoutines = try c.decodeIfPresent(Bool.self, forKey: .notifyRoutines) ?? true
        botUsername = try c.decodeIfPresent(String.self, forKey: .botUsername)
    }
}

// MARK: - Wire types

public struct TelegramUpdate: Sendable, Equatable {
    public var updateId: Int
    public var chatId: Int64
    public var isPrivate: Bool
    public var userId: Int64?
    public var username: String?
    public var firstName: String?
    /// nil when the message carried no text (a photo, a sticker…).
    public var text: String?

    public init(
        updateId: Int, chatId: Int64, isPrivate: Bool = true, userId: Int64? = nil,
        username: String? = nil, firstName: String? = nil, text: String? = nil
    ) {
        self.updateId = updateId
        self.chatId = chatId
        self.isPrivate = isPrivate
        self.userId = userId
        self.username = username
        self.firstName = firstName
        self.text = text
    }

    public var displayName: String {
        if let username, !username.isEmpty { return "@\(username)" }
        return firstName ?? "someone"
    }
}

public enum TelegramError: Error, LocalizedError, Sendable {
    case notConfigured
    case api(code: Int, description: String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a Telegram bot token first."
        case .api(let code, let description): return "Telegram said \(code): \(description)"
        case .badResponse: return "Telegram sent something unreadable."
        }
    }
}

/// The slice of the Bot API GrizzyBot uses. A protocol so tests can stand in for the network.
public protocol TelegramAPI: Sendable {
    func getMe() async throws -> String
    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate]
    func sendMessage(chatId: Int64, text: String) async throws
    func sendTyping(chatId: Int64) async
}

public struct TelegramBotAPI: TelegramAPI {
    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> Any {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, _) = try await session.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelegramError.badResponse
        }
        guard object["ok"] as? Bool == true else {
            throw TelegramError.api(
                code: object["error_code"] as? Int ?? 0,
                description: object["description"] as? String ?? "unknown error"
            )
        }
        return object["result"] ?? [:]
    }

    public func getMe() async throws -> String {
        let result = try await call("getMe", [:]) as? [String: Any]
        return result?["username"] as? String ?? ""
    }

    public func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] {
        let result = try await call(
            "getUpdates",
            ["offset": offset, "timeout": timeout, "allowed_updates": ["message"]],
            timeout: TimeInterval(timeout + 15)
        )
        return TelegramParsing.updates(from: result)
    }

    public func sendMessage(chatId: Int64, text: String) async throws {
        for chunk in TelegramFormat.chunks(text) {
            _ = try await call("sendMessage", ["chat_id": chatId, "text": chunk, "disable_web_page_preview": true])
        }
    }

    public func sendTyping(chatId: Int64) async {
        _ = try? await call("sendChatAction", ["chat_id": chatId, "action": "typing"], timeout: 10)
    }
}

public enum TelegramParsing {
    public static func updates(from result: Any) -> [TelegramUpdate] {
        guard let list = result as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["update_id"] as? Int,
                  let message = item["message"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any],
                  let chatId = (chat["id"] as? NSNumber)?.int64Value
            else { return nil }
            let from = message["from"] as? [String: Any]
            return TelegramUpdate(
                updateId: id,
                chatId: chatId,
                isPrivate: (chat["type"] as? String) == "private",
                userId: (from?["id"] as? NSNumber)?.int64Value,
                username: from?["username"] as? String,
                firstName: from?["first_name"] as? String,
                text: message["text"] as? String
            )
        }
    }
}

// MARK: - Text

public enum TelegramFormat {
    /// Telegram caps a message at 4096 characters; stay under it and break on paragraph/line/space.
    public static func chunks(_ text: String, limit: Int = 3_900) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }
        var out: [String] = []
        var rest = Substring(trimmed)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = ["\n\n", "\n", " "].lazy
                .compactMap { window.range(of: $0, options: .backwards) }
                .first { window.distance(from: window.startIndex, to: $0.lowerBound) > limit / 2 }
            let end = cut?.upperBound ?? window.endIndex
            out.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}

/// Things a person can type in the chat instead of talking to the bot.
public enum TelegramCommand: Equatable, Sendable {
    case start
    case help
    case bots
    case use(String)
    case status
    case stop
    case approve
    case deny
    case message(String)

    public static func parse(_ raw: String) -> TelegramCommand {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return .message(text) }
        let body = text.dropFirst()
        let head = body.prefix { !$0.isWhitespace }
        // "/status@MyBot" is how Telegram addresses a command in a group.
        let name = head.split(separator: "@").first.map { String($0).lowercased() } ?? ""
        let arg = body.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "start": return .start
        case "help": return .help
        case "bots", "list": return .bots
        case "bot", "use", "switch": return arg.isEmpty ? .bots : .use(arg)
        case "status": return .status
        case "stop", "cancel": return .stop
        case "approve", "yes", "allow": return .approve
        case "deny", "no": return .deny
        default: return .message(text)
        }
    }

    public static let helpText = """
    I pass your messages to your GrizzyBot bots on your Mac.

    Just type to talk to the current bot. Commands:
    /bots — list your bots
    /bot <name> — switch to a bot
    /status — what the current bot is doing
    /stop — stop its current run
    /approve · /deny — answer an approval it is waiting on
    """
}

/// Short-lived codes that let a new chat prove it belongs to the person at the Mac.
public struct TelegramPairing: Sendable {
    public struct Pending: Sendable, Equatable {
        public var code: String
        public var chatId: Int64
        public var name: String
        public var expires: Date
    }

    public static let lifetime: TimeInterval = 3_600
    public static let maxPending = 3

    public private(set) var pending: [Pending] = []

    public init() {}

    /// Issues (or re-issues) a code for this chat, or nil if too many are already waiting.
    public mutating func issue(chatId: Int64, name: String, now: Date = .now) -> String? {
        pending.removeAll { $0.expires <= now }
        if let existing = pending.first(where: { $0.chatId == chatId }) { return existing.code }
        guard pending.count < Self.maxPending else { return nil }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pending.append(Pending(code: code, chatId: chatId, name: name, expires: now.addingTimeInterval(Self.lifetime)))
        return code
    }

    /// Consumes a code and returns the chat it belongs to.
    public mutating func redeem(_ code: String, now: Date = .now) -> Pending? {
        pending.removeAll { $0.expires <= now }
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = pending.firstIndex(where: { WebhookSecret.matches(cleaned, $0.code) }) else { return nil }
        return pending.remove(at: idx)
    }

    public func active(now: Date = .now) -> [Pending] {
        pending.filter { $0.expires > now }
    }
}
