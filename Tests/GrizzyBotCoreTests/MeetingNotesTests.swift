import Foundation
@testable import GrizzyBotCore
import Testing

@Suite("Meeting notes")
struct MeetingNotesTests {
    private let json = #"{"summary":"Agreed to ship Friday.","decisions":["Ship Friday"],"actionItems":[{"owner":"Ana","task":"Write release notes","due":"Thu"},{"owner":"","task":"Book the room","due":""}],"openQuestions":["Who approves?"],"attendees":["Ana","Ben"]}"#

    @Test("meeting links are recognised, and Zoom is named so it can be refused")
    func links() {
        #expect(MeetingLink.detect(in: "join https://meet.google.com/abc-defg-hij now")?.provider == .googleMeet)
        #expect(MeetingLink.detect(in: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=1")?.provider == .teams)
        #expect(MeetingLink.detect(in: "https://teams.live.com/meet/9312")?.provider == .teams)
        #expect(MeetingLink.detect(in: "https://meet.jit.si/StandupRoom")?.provider == .jitsi)
        #expect(MeetingLink.detect(in: "https://acme.zoom.us/j/123456789?pwd=x")?.provider == .zoom)
        #expect(MeetingLink.detect(in: "https://example.com/meet") == nil)
        #expect(MeetingLink.detect(in: "https://meet.google.com/lookup")?.provider == nil)
        #expect(MeetingLink.detect(in: "https://meet.google.com/abc-defg-hij")!.explanation.contains("can't join"))
    }

    @Test("a WebVTT export is reduced to speaker lines")
    func vtt() {
        let raw = """
        WEBVTT

        NOTE made by a tool

        1
        00:00:01.000 --> 00:00:04.000
        <v Ana>Let's ship on Friday.</v>

        2
        00:00:04.500 --> 00:00:06.000
        <v Ana>I will write the notes.</v>

        3
        00:00:06.500 --> 00:00:08.000
        <v Ben>Fine by me.</v>
        """
        #expect(MeetingTranscript.clean(raw) == "Ana: Let's ship on Friday. I will write the notes.\nBen: Fine by me.")
    }

    @Test("an SRT export and plain 'Name: text' lines clean the same way")
    func srtAndPlain() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nAna: Hello all\n\n2\n00:00:02,500 --> 00:00:03,000\nAna: Starting now\n"
        #expect(MeetingTranscript.clean(srt) == "Ana: Hello all Starting now")
        #expect(MeetingTranscript.clean("just some words\nmore words") == "just some words\nmore words")
        #expect(MeetingTranscript.clean("  \n\n") == "")
    }

    @Test("chunks respect the limit and lose nothing")
    func chunking() {
        let lines = (0..<200).map { "Speaker \($0 % 3): " + String(repeating: "word ", count: 20) }
        let text = lines.joined(separator: "\n")
        let parts = MeetingTranscript.chunks(text, maxChars: 1_000)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= 1_000 })
        #expect(parts.joined(separator: "\n") == text)
        let long = String(repeating: "x", count: 2_500)
        #expect(MeetingTranscript.chunks(long, maxChars: 1_000).map(\.count) == [1_000, 1_000, 500])
    }

    @Test("notes parse from a reply wrapped in prose, and unusable replies are nil")
    func parsing() throws {
        let notes = try #require(MeetingNotes.parse(reply: "Here you go:\n```json\n\(json)\n```", title: "Launch sync"))
        #expect(notes.title == "Launch sync")
        #expect(notes.decisions == ["Ship Friday"])
        #expect(notes.actionItems.count == 2)
        #expect(notes.actionItems[0] == .init(owner: "Ana", task: "Write release notes", due: "Thu"))
        #expect(notes.actionItems[1].owner.isEmpty)
        #expect(MeetingNotes.parse(reply: "I could not do that.") == nil)
        #expect(MeetingNotes.parse(reply: "{}") == nil)
        let sloppy = try #require(MeetingNotes.parse(reply: #"{"summary":"s","actionItems":["call Dana",{"task":""},{"task":"x"}]}"#))
        #expect(sloppy.actionItems.map(\.task) == ["call Dana", "x"])
    }

    @Test("markdown and card carry the sections, with unowned items marked")
    func rendering() throws {
        let notes = try #require(MeetingNotes.parse(reply: json, title: "Launch sync"))
        let md = notes.markdown()
        #expect(md.hasPrefix("# Launch sync"))
        #expect(md.contains("## Decisions") && md.contains("- Ship Friday"))
        #expect(md.contains("- [ ] **Ana:** Write release notes (due Thu)"))
        #expect(md.contains("- [ ] **Unassigned:** Book the room"))
        #expect(md.contains("## Attendees"))
        let card = notes.cardLines
        #expect(card.contains { $0.k == "action items" && $0.v == "2" })
        #expect(card.contains { $0.k == "Ana" })
    }

    @Test("a short transcript is one call; an invalid reply is retried once, then reported")
    func writer() async throws {
        let counter = Counter()
        let notes = try await MeetingNotesWriter.write(transcript: "Ana: Ship Friday.", title: "T") { _ in
            counter.bump() == 1 ? "sorry, no" : json
        }
        #expect(counter.value == 2)
        #expect(notes.decisions == ["Ship Friday"])

        await #expect(throws: MeetingNotesWriter.WriterError.unreadableReply) {
            try await MeetingNotesWriter.write(transcript: "Ana: hi", title: "") { _ in "nope" }
        }
        await #expect(throws: MeetingNotesWriter.WriterError.emptyTranscript) {
            try await MeetingNotesWriter.write(transcript: "WEBVTT\n\n", title: "") { _ in json }
        }
    }

    @Test("a long transcript is done in parts and merged without repeats")
    func longTranscript() async throws {
        let line = "Ana: " + String(repeating: "discussion ", count: 60)
        let transcript = Array(repeating: line, count: 120).joined(separator: "\n")  // ~ 80k chars
        let counter = Counter()
        let prompts = Locked<[String]>([])
        let notes = try await MeetingNotesWriter.write(transcript: transcript, title: "Big") { messages in
            counter.bump()
            prompts.with { $0.append(messages.last?.content ?? "") }
            return json
        }
        #expect(counter.value > 1)
        #expect(counter.value <= MeetingNotesWriter.maxChunks)
        #expect(prompts.value.first?.contains("part 1 of") == true)
        #expect(notes.decisions == ["Ship Friday"])
        #expect(notes.actionItems.count == 2)
        #expect(notes.attendees == ["Ana", "Ben"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    @discardableResult func bump() -> Int { lock.withLock { n += 1; return n } }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func with(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

@Suite("Meeting notes in a bot")
@MainActor
struct MeetingNotesBotTests {
    private func world() -> (store: AppStore, bot: Bot) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        _ = store.signUp(name: "T", email: "m\(UUID().uuidString.prefix(6))@b.com", password: "password1")
        let bot = store.createBot(name: "Scribe", title: "Notes", enabledTools: ["meeting_notes", "read_file"])
        return (store, bot)
    }

    @Test("/meeting with pasted text runs the tool, saves an artifact and posts a card")
    func endToEnd() async throws {
        let w = world()
        let notesJSON = #"{"summary":"Ship Friday.","decisions":["Ship Friday"],"actionItems":[{"owner":"Ana","task":"Notes","due":""}],"openQuestions":[],"attendees":["Ana"]}"#
        let client = ByBotClient([
            "Scribe": [
                .success(ChatCompletionResponse(toolCalls: [LLMToolCall(id: "1", name: "meeting_notes", arguments: #"{"path":"meetings/x.txt","title":"Sync"}"#)])),
                .success(ChatCompletionResponse(text: "Ship Friday; Ana owes the notes.")),
            ],
            "?": [.success(ChatCompletionResponse(text: notesJSON))],
        ])
        w.store.chatCompleter = client
        // The scripted model reads a fixed path, so seed it with the same transcript.
        w.store.writeBotFile(botId: w.bot.id, path: "meetings/x.txt", content: "Ana: Let's ship Friday.\nAna: I'll write the notes.")
        // The pasted transcript is saved to the bot's home and the model is handed its path.
        w.store.send(botId: w.bot.id, text: "/meeting Ana: Let's ship Friday.\nAna: I'll write the notes.")
        await w.store.waitForActiveRuns()
        #expect(client.calls(for: "?") == 1)
        let prompt = client.requests(for: "Scribe").first?.last?.content ?? ""
        #expect(prompt.contains("meeting_notes") && prompt.contains("meetings/transcript-"))
        #expect(!prompt.contains("Let's ship Friday"))
        #expect(w.store.artifacts.contains { $0.title.contains("notes") })
    }

    @Test("/meeting with only a link explains the limit and does not call the model")
    func linkOnly() async {
        let w = world()
        let client = ByBotClient([:])
        w.store.chatCompleter = client
        w.store.send(botId: w.bot.id, text: "/meeting https://meet.google.com/abc-defg-hij")
        await w.store.waitForActiveRuns()
        #expect(client.calls(for: "Scribe") == 0)
        let reply = w.store.threads[w.bot.id]?.messages.last?.firstText ?? ""
        #expect(reply.contains("can't join"))
    }

    @Test("/meeting asks you to turn the tool on when the bot lacks it")
    func toolOff() async {
        let w = world()
        w.store.setBotTool(w.bot.id, toolId: "meeting_notes", enabled: false)
        w.store.chatCompleter = ByBotClient([:])
        w.store.send(botId: w.bot.id, text: "/meeting Ana: hi")
        await w.store.waitForActiveRuns()
        #expect((w.store.threads[w.bot.id]?.messages.last?.firstText ?? "").contains("Meeting notes"))
    }
}
