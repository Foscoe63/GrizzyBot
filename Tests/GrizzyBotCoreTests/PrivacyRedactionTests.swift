import Foundation
import GrizzyBotCore
import Testing

@Suite("Privacy redaction")
struct PrivacyRedactionTests {
    @Test("placeholders are stable and reversible")
    func reversible() {
        let session = RedactionSession()
        let r = PrivacyFilter.redact("Mail ada@example.com then ada@example.com again", settings: .default, session: session)
        #expect(r.redactedText == "Mail [EMAIL_1] then [EMAIL_1] again")
        #expect(session.unscrub("Sent to [EMAIL_1].") == "Sent to ada@example.com.")
    }

    @Test("a placeholder split across stream chunks is still put back")
    func streaming() {
        let session = RedactionSession()
        _ = session.placeholder(for: "ada@example.com", type: .email)
        var un = StreamingUnscrubber(session: session)
        let out = un.feed("Write to [EMA") + un.feed("IL_1] today") + un.finish()
        #expect(out == "Write to ada@example.com today")
        var plain = StreamingUnscrubber(session: session)
        #expect(plain.feed("a [list] item") + plain.finish() == "a [list] item")
    }

    @Test("never-redact and per-conversation allows are honoured")
    func choices() {
        var settings = PrivacyFilterSettings.default
        settings.neverRedact = ["support@acme.com"]
        #expect(!PrivacyFilter.redact("ask support@acme.com", settings: settings).wasModified)
        let session = RedactionSession()
        session.allow("bob@example.com")
        #expect(!PrivacyFilter.redact("bob@example.com", settings: .default, session: session).wasModified)
        #expect(PrivacyFilter.redact("eve@example.com", settings: .default, session: session).wasModified)
    }

    @Test("the review preview splits the message and rebuilds the scrubbed text")
    func preview() {
        let text = "Hi, my mail is ada@example.com ok?"
        let preview = RedactionPreview.make(for: text, settings: .default)
        #expect(preview.original == text)
        #expect(preview.segments.contains { $0.isRedacted && $0.type == .email })
        #expect(preview.scrubbed == PrivacyFilter.redact(text).redactedText)
    }

    @Test("on-device detector can be switched on and keeps settings round-tripping")
    func onDevice() throws {
        var settings = PrivacyFilterSettings.default
        settings.useOnDeviceNER = true
        settings.neverRedact = ["Acme"]
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(PrivacyFilterSettings.self, from: data)
        #expect(back.useOnDeviceNER && back.neverRedact == ["Acme"])
        #expect(!PrivacyFilter.redact("Tim Cook visited Paris", settings: settings).detections.isEmpty)
        #expect(PrivacyFilter.survivingCritical(in: "key sk-abcdefghijklmnopqrstuvwx", settings: .default).isEmpty == false)
    }
}

@Suite("Privacy in the send path")
@MainActor
struct PrivacySendPathTests {
    @Test("the model sees a placeholder, the person sees the real address in the reply")
    func roundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        #expect(store.signUp(name: "A", email: "priv@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        let client = QueueChatClient([ChatCompletionResponse(text: "I will write to [EMAIL_1] now.")])
        store.chatCompleter = client
        store.send(botId: bot.id, text: "please email ada@example.com about lunch")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let sent = client.requests.flatMap(\.messages).compactMap(\.content).joined(separator: "\n")
        #expect(sent.contains("[EMAIL_1]"))
        #expect(!sent.contains("ada@example.com"))
        let reply = store.threads[bot.id]?.messages.last?.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined()
        #expect(reply?.contains("ada@example.com") == true)
    }
}

@MainActor
@Suite("Local gateway runs a bot")
struct GatewayRunTests {
    @Test("the caller gets the bot's real reply, not a queued notice")
    func realReply() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        #expect(store.signUp(name: "A", email: "gw@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        store.chatCompleter = QueueChatClient([ChatCompletionResponse(text: "Paris.")])
        let reply = try await store.gatewayRun(botId: bot.id, messages: [["role": "user", "content": "capital of France?"]], onDelta: { _ in })
        #expect(reply == "Paris.")
    }
}
