import Foundation
import GrizzyBotCore
import Testing

@Suite("Bot library")
struct BotLibraryTests {
    private func message(_ id: String, _ role: MessageRole, _ blocks: [MessageBlock], daysAgo: Int = 0) -> ThreadMessage {
        ThreadMessage(
            id: id, threadId: "t", seq: 0, role: role, blocks: blocks,
            createdAt: Date.now.addingTimeInterval(-TimeInterval(daysAgo) * 86_400 - 5)
        )
    }

    @Test("artifacts, written files, and links the bot shared are collected newest first")
    func collects() {
        let thread = ThreadData(threadId: "t", messages: [
            message("1", .bot, [.artifact(id: "a1", title: "Plan", kind: .markdown, summary: "v1", deleted: false)], daysAgo: 3),
            message("2", .bot, [.card(lines: [CardLine(k: "wrote", v: "notes/report.md"), CardLine(k: "diff", v: "+x")])], daysAgo: 1),
            message("3", .bot, [.text("See https://example.com/docs and also https://example.com/docs again.")]),
            message("4", .user, [.text("my own link https://user.example/")]),
            message("5", .bot, [.artifact(id: "a2", title: "Gone", kind: .code, summary: "", deleted: true)]),
        ])
        let items = BotLibrary.items(in: thread)
        #expect(items.map(\.kind) == [.link, .file, .artifact])
        #expect(items[0].target == "https://example.com/docs")
        #expect(items[1].title == "report.md")
        #expect(items[2].target == "a1")
    }

    @Test("items group into today, this week, and older")
    func groups() {
        let now = Date.now
        func item(_ days: Int) -> SharedItem {
            SharedItem(id: "\(days)", kind: .link, title: "t", detail: "d", date: now.addingTimeInterval(-TimeInterval(days) * 86_400), target: "\(days)")
        }
        let grouped = BotLibrary.grouped([item(0), item(40)], now: now)
        #expect(grouped.map(\.bucket) == [.today, .older])
    }
}

@Suite("Approval from a notification")
@MainActor
struct NotificationApprovalTests {
    @Test("answering the pending approval resolves it the same way the card does")
    func answers() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        #expect(store.signUp(name: "A", email: "n@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent", title: "helper")
        var notified: [String] = []
        store.onApprovalNeeded = { _, tool, _ in notified.append(tool) }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "shell", arguments: "{\"command\":\"echo hi\"}")]),
            ChatCompletionResponse(text: "waiting"),
        ])
        store.send(botId: bot.id, text: "run echo hi")
        #expect(await store.waitForPendingTool(botId: bot.id))
        #expect(notified == ["shell.exec"])
        #expect(store.pendingApprovalMessageId(botId: bot.id) != nil)
        #expect(store.answerPendingApproval(botId: bot.id, decision: .deny))
        #expect(store.threads[bot.id]?.pendingTool == nil)
        #expect(store.pendingApprovalMessageId(botId: bot.id) == nil)
        #expect(!store.answerPendingApproval(botId: bot.id, decision: .allow))
    }
}

@Suite("Bot accent")
struct BotAccentTests {
    @Test("light colours get dark text, dark colours get light text")
    func contrast() {
        #expect(BotAccent.prefersLightText(onHex: "#1B2A6B"))
        #expect(!BotAccent.prefersLightText(onHex: "#F5E663"))
        #expect(BotAccent.prefersLightText(onHex: "#7C3AED"))
        #expect(!BotAccent.prefersLightText(onHex: "not a colour"))
    }

    @Test("only six-digit hex parses")
    func parse() {
        #expect(BotAccent.rgb("#FF0000")! == (1, 0, 0))
        #expect(BotAccent.rgb("#FFF") == nil)
        #expect(BotAccent.rgb("zzzzzz") == nil)
    }
}

@Suite("Quoting")
struct QuoteTests {
    @Test("a selection becomes a blockquote above the draft")
    func quote() {
        #expect(QuoteFormatter.blockquote("  one\n\ntwo  ") == "> one\n>\n> two")
        #expect(QuoteFormatter.blockquote("   ") == nil)
        #expect(QuoteFormatter.compose(draft: "", quote: "hello") == "> hello\n\n")
        #expect(QuoteFormatter.compose(draft: "my reply", quote: "hello") == "> hello\n\nmy reply")
        #expect(QuoteFormatter.compose(draft: "keep", quote: " ") == "keep")
        #expect(QuoteFormatter.blockquote(String(repeating: "a", count: 5_000))!.count < 4_010)
    }
}

@Suite("Voice transcript")
struct VoiceTranscriptTests {
    @Test("Markdown marks are dropped from what is read and shown")
    func plain() {
        #expect(VoiceTranscript.plainText(fromMarkdown: "**Bold** and a [link](https://x.test) here.") == "Bold and a link here.")
    }

    @Test("words carry UTF-16 offsets and tapping maps back to a word")
    func words() {
        let text = "Hello brave new world"
        let words = VoiceTranscript.words(in: text)
        #expect(words.count == 4)
        #expect(words[1] == .init(offset: 6, length: 5))
        #expect(VoiceTranscript.wordIndex(at: 8, in: words) == 1)
        #expect(VoiceTranscript.wordIndex(at: 5, in: words) == 1) // the space before "brave" → next word
        #expect(VoiceTranscript.wordIndex(at: 99, in: words) == nil)
        #expect(VoiceTranscript.suffix(of: text, from: words[2].offset) == "new world")
        #expect(VoiceTranscript.suffix(of: text, from: 0) == text)
    }

    @Test("offsets stay right with emoji and accents")
    func unicode() {
        let text = "café 🎉 party"
        let words = VoiceTranscript.words(in: text)
        let ns = text as NSString
        #expect(words.map { ns.substring(with: NSRange(location: $0.offset, length: $0.length)) } == ["café", "party"])
    }
}

@Suite("Deep links")
struct DeepLinkTests {
    private func parse(_ s: String) -> DeepLink? { DeepLink.parse(URL(string: s)!) }

    @Test("open, ask, and run-routine parse; everything else is ignored")
    func parsing() {
        #expect(parse("grizzybot://open?bot=Ada") == .open(bot: "Ada"))
        #expect(parse("grizzybot://ask?bot=Ada&text=what%20changed%3F") == .ask(bot: "Ada", text: "what changed?"))
        #expect(parse("grizzybot://run-routine?name=Morning%20brief") == .runRoutine(name: "Morning brief"))
        #expect(parse("grizzybot://ask?bot=Ada") == nil)
        #expect(parse("grizzybot://delete-everything?bot=Ada") == nil)
        #expect(parse("https://example.com/ask?bot=Ada&text=x") == nil)
    }

    @Test("only opening a chat skips the confirmation, and long text is clipped")
    func confirmation() {
        #expect(DeepLink.open(bot: "Ada").needsConfirmation == false)
        #expect(DeepLink.ask(bot: "Ada", text: "x").needsConfirmation)
        #expect(DeepLink.runRoutine(name: "x").needsConfirmation)
        let long = String(repeating: "a", count: 5_000)
        guard case .ask(_, let text)? = parse("grizzybot://ask?bot=Ada&text=\(long)") else { Issue.record("expected ask"); return }
        #expect(text.count == DeepLink.maxTextLength)
    }
}
