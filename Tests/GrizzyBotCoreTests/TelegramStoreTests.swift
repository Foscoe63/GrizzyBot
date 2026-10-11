import Foundation
import GrizzyBotCore
import Testing

private final class FakeTelegram: TelegramAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var sentLog: [(Int64, String)] = []

    var sent: [(Int64, String)] {
        lock.lock(); defer { lock.unlock() }
        return sentLog
    }
    func getMe() async throws -> String { "grizzy_test_bot" }
    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] { [] }
    private func record(_ chatId: Int64, _ text: String) {
        lock.lock(); sentLog.append((chatId, text)); lock.unlock()
    }
    func sendMessage(chatId: Int64, text: String) async throws {
        record(chatId, text)
    }
    func sendTyping(chatId: Int64) async {}
}

@Suite("Telegram in the store")
@MainActor
struct TelegramStoreTests {
    private func makeStore(email: String) -> (AppStore, FakeTelegram) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        store.appConfig.enableFolderWatchers = false
        _ = email // the local session is the owner; a sign-up would make this an operator
        let fake = FakeTelegram()
        store.setTelegramAPIForTesting(fake)
        return (store, fake)
    }

    private func update(_ chat: Int64, _ text: String, id: Int = 1) -> TelegramUpdate {
        TelegramUpdate(updateId: id, chatId: chat, userId: chat, username: "ed", text: text)
    }

    private func settle(_ fake: FakeTelegram, count: Int) async {
        for _ in 0..<200 {
            if fake.sent.count >= count { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("an unknown chat gets a pairing code and no bot access until the owner enters it")
    func pairingFlow() async {
        let (store, fake) = makeStore(email: "tg-pair@b.com")
        let ok = await store.connectTelegram(token: "123:abc")
        #expect(ok == nil)
        let bot = store.createBot(name: "Ada", title: "")
        store.handleTelegramUpdate(update(55, "hello"))
        await settle(fake, count: 1)
        #expect(fake.sent.first?.1.contains("code") == true)
        // Nothing reached the bot.
        #expect((store.threads[bot.id]?.messages.filter { $0.role == .user }.count ?? 0) == 0)

        let code = store.telegramPairingRequests.first?.code ?? ""
        #expect(!code.isEmpty)
        #expect(store.approveTelegramPairing(code: "nope") == nil)
        #expect(store.approveTelegramPairing(code: code) != nil)
        #expect(store.appConfig.telegram.allowedChatIds == [55])
        #expect(store.approveTelegramPairing(code: code) == nil)
    }

    @Test("groups are ignored even when the chat id is allowed")
    func groupsIgnored() async {
        let (store, fake) = makeStore(email: "tg-group@b.com")
        _ = await store.connectTelegram(token: "123:abc")
        store.appConfig.telegram.allowedChatIds = [9]
        store.handleTelegramUpdate(TelegramUpdate(updateId: 1, chatId: 9, isPrivate: false, text: "hi"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fake.sent.isEmpty)
    }

    @Test("a paired chat's message runs the bot and the answer comes back")
    func roundTrip() async {
        let (store, fake) = makeStore(email: "tg-round@b.com")
        _ = await store.connectTelegram(token: "123:abc")
        let bot = store.createBot(name: "Ada", title: "")
        store.appConfig.telegram.allowedChatIds = [7]
        store.chatCompleter = QueueChatClient([ChatCompletionResponse(text: "Four.")])
        store.handleTelegramUpdate(update(7, "what is 2+2"))
        await settle(fake, count: 1)
        #expect(fake.sent.last?.0 == 7)
        #expect(fake.sent.last?.1 == "Four.")
        #expect(store.threads[bot.id]?.messages.contains { $0.role == .user && $0.firstText == "what is 2+2" } == true)
    }

    @Test("/bot switches which bot a chat talks to; /bots lists them")
    func switching() async {
        let (store, fake) = makeStore(email: "tg-switch@b.com")
        _ = await store.connectTelegram(token: "123:abc")
        let ada = store.createBot(name: "Ada", title: "Analyst")
        let grace = store.createBot(name: "Grace", title: "")
        store.appConfig.telegram.allowedChatIds = [7]
        store.handleTelegramUpdate(update(7, "/bots", id: 1))
        store.handleTelegramUpdate(update(7, "/bot gra", id: 2))
        await settle(fake, count: 2)
        #expect(fake.sent.contains { $0.1.contains("Ada") && $0.1.contains("Grace") })
        #expect(store.appConfig.telegram.chatBots["7"] == grace.id)
        #expect(store.appConfig.telegram.chatBots["7"] != ada.id)
        store.handleTelegramUpdate(update(7, "/bot nobody", id: 3))
        await settle(fake, count: 3)
        #expect(fake.sent.last?.1.contains("No bot called") == true)
    }

    @Test("revoking a chat removes access")
    func revoke() async {
        let (store, fake) = makeStore(email: "tg-revoke@b.com")
        _ = await store.connectTelegram(token: "123:abc")
        store.appConfig.telegram.allowedChatIds = [7]
        store.revokeTelegramChat(7)
        store.handleTelegramUpdate(update(7, "hi"))
        await settle(fake, count: 1)
        #expect(fake.sent.first?.1.contains("code") == true)
    }

    @Test("disconnecting forgets the token and every paired chat")
    func disconnect() async {
        let (store, _) = makeStore(email: "tg-off@b.com")
        _ = await store.connectTelegram(token: "123:abc")
        store.appConfig.telegram.allowedChatIds = [7]
        store.disconnectTelegram()
        #expect(store.telegramToken == nil)
        #expect(store.appConfig.telegram.allowedChatIds.isEmpty)
        #expect(!store.appConfig.telegram.enabled)
    }
}
