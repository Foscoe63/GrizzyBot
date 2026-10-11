import AppIntents
import AppKit
@preconcurrency import CoreSpotlight
import GrizzyBotCore

/// Lets the rest of macOS reach the running app: Siri, Shortcuts, and Spotlight.
@MainActor
enum MacBridge {
    /// Set once the app has built its store; intents run in the app process and read it from here.
    static var store: AppStore?
    static let spotlightDomain = "com.grizzybot.bots"
    static let activityType = "com.grizzybot.open-bot"

    /// Put every visible bot into Spotlight so ⌘Space finds it and opens its chat.
    static func indexBots(_ bots: [Bot]) {
        let items = bots.filter { !$0.hidden }.map { bot -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = bot.name
            attributes.contentDescription = bot.title.isEmpty ? bot.description : bot.title
            attributes.keywords = ["GrizzyBot", "bot", bot.name]
            return CSSearchableItem(uniqueIdentifier: bot.id, domainIdentifier: spotlightDomain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Spotlight hands back the bot id when a result is opened.
    static func openBot(id: String) {
        guard let store, store.bots.contains(where: { $0.id == id }) else { return }
        store.selectBot(id)
        store.showChat()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct BotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotEntityQuery()

    var id: String
    var name: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: title.isEmpty ? nil : "\(title)")
    }
}

struct BotEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [BotEntity] {
        let q = string.lowercased()
        return all().filter { $0.name.lowercased().contains(q) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BotEntity] { all() }

    @MainActor
    private func all() -> [BotEntity] {
        (MacBridge.store?.bots ?? []).filter { !$0.hidden }.map { BotEntity(id: $0.id, name: $0.name, title: $0.title) }
    }
}

/// "Ask Researcher in GrizzyBot: what changed in the news today?" — from Siri, Spotlight, or a Shortcut.
struct AskBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Bot"
    static let description = IntentDescription("Send a message to one of your GrizzyBot bots and get its reply.")

    @Parameter(title: "Bot") var bot: BotEntity
    @Parameter(title: "Message") var message: String
    @Parameter(title: "Seconds to wait", default: 60) var waitSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$bot) \(\.$message)") {
            \.$waitSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = MacBridge.store else {
            return .result(value: "GrizzyBot isn't ready yet. Open it once and try again.")
        }
        store.send(botId: bot.id, text: message)
        let done = await store.waitForRunCompletion(botId: bot.id, timeout: TimeInterval(min(max(waitSeconds, 1), 300)))
        if store.pendingApprovalMessageId(botId: bot.id) != nil {
            return .result(value: "\(bot.name) is waiting for your approval in GrizzyBot.")
        }
        let reply = store.lastBotReply(botId: bot.id)
        if reply.isEmpty { return .result(value: done ? "\(bot.name) finished without a text reply." : "\(bot.name) is still working.") }
        return .result(value: reply)
    }
}

/// Fire one of a bot's routines now — the way a Shortcut, Focus filter, or automation triggers work.
struct RunRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Routine"
    static let description = IntentDescription("Start one of your GrizzyBot routines.")

    @Parameter(title: "Routine name") var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = MacBridge.store else { return .result(value: "GrizzyBot isn't ready yet.") }
        let wanted = name.lowercased()
        for (_, list) in store.routines {
            if let routine = list.first(where: { $0.name.lowercased() == wanted }) {
                store.runRoutine(routine.id)
                return .result(value: "Started “\(routine.name)”.")
            }
        }
        return .result(value: "No routine named “\(name)”.")
    }
}

struct GrizzyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskBotIntent(),
            phrases: ["Ask \(\.$bot) in \(.applicationName)", "Message \(\.$bot) in \(.applicationName)"],
            shortTitle: "Ask a Bot",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
