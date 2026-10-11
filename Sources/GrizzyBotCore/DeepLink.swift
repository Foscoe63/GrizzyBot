import Foundation

/// `grizzybot://` links: the hook for Shortcuts ("Open URL"), shell scripts (`open grizzybot://…`),
/// Alfred, Raycast, and Focus automations. Any web page can open one too, so every link that does
/// work (rather than just showing a bot) is read back to the person for a yes first.
public enum DeepLink: Equatable, Sendable {
    case open(bot: String)
    case ask(bot: String, text: String)
    case runRoutine(name: String)

    public static let scheme = "grizzybot"
    public static let maxTextLength = 2_000

    /// `grizzybot://open?bot=Ada`, `grizzybot://ask?bot=Ada&text=hello`, `grizzybot://run-routine?name=Morning`.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme,
              let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ key: String) -> String {
            (items.first { $0.name == key }?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch host {
        case "open":
            let bot = value("bot")
            return bot.isEmpty ? nil : .open(bot: bot)
        case "ask":
            let bot = value("bot"), text = value("text")
            guard !bot.isEmpty, !text.isEmpty else { return nil }
            return .ask(bot: bot, text: String(text.prefix(maxTextLength)))
        case "run-routine":
            let name = value("name")
            return name.isEmpty ? nil : .runRoutine(name: name)
        default:
            return nil
        }
    }

    /// Whether the link makes a bot do something, and so needs a confirmation.
    public var needsConfirmation: Bool {
        if case .open = self { return false }
        return true
    }

    public var summary: String {
        switch self {
        case .open(let bot): return "Open the chat with \(bot)."
        case .ask(let bot, let text): return "Send this to \(bot):\n\n“\(String(text.prefix(300)))”"
        case .runRoutine(let name): return "Run the routine “\(name)”."
        }
    }
}

extension AppStore {
    /// Carries out a confirmed link. Returns a message when it could not.
    @discardableResult
    public func perform(_ link: DeepLink) -> String? {
        switch link {
        case .open(let bot):
            guard let found = findBot(bot) else { return "No bot named “\(bot)”." }
            selectBot(found.id)
            showChat()
        case .ask(let bot, let text):
            guard let found = findBot(bot) else { return "No bot named “\(bot)”." }
            selectBot(found.id)
            showChat()
            send(botId: found.id, text: text)
        case .runRoutine(let name):
            let wanted = name.lowercased()
            for (_, list) in routines {
                if let routine = list.first(where: { $0.name.lowercased() == wanted }) {
                    runRoutine(routine.id)
                    return nil
                }
            }
            return "No routine named “\(name)”."
        }
        return nil
    }
}
