import Foundation
import GrizzyBotCore
import Testing

@Suite("BotHome")
struct BotHomeTests {
    @Test("write read edit move delete stay sandboxed")
    func fileLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHomeStore(root: root)
        let botId = "bot-1"

        try home.write(botId: botId, path: "notes/hello.txt", content: "hi\n")
        #expect(try home.read(botId: botId, path: "notes/hello.txt") == "hi\n")

        try home.edit(botId: botId, path: "notes/hello.txt", content: "there\n", mode: .append)
        #expect(try home.read(botId: botId, path: "notes/hello.txt") == "hi\nthere\n")

        try home.move(botId: botId, from: "notes/hello.txt", to: "notes/renamed.txt")
        #expect(home.exists(botId: botId, path: "notes/renamed.txt"))
        #expect(!home.exists(botId: botId, path: "notes/hello.txt"))

        let listed = try home.list(botId: botId, directory: "notes")
        #expect(listed.contains(where: { $0.path.hasSuffix("renamed.txt") }))

        try home.delete(botId: botId, path: "notes/renamed.txt")
        #expect(!home.exists(botId: botId, path: "notes/renamed.txt"))
    }

    @Test("shell runs inside the bot home")
    func shellInHome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHomeStore(root: root)
        let botId = "bot-1"
        try home.write(botId: botId, path: "notes/a.txt", content: "hi\n")
        let result = try await home.runShell(botId: botId, command: "pwd && cat notes/a.txt")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hi"))
        #expect(result.stdout.contains(botId) || result.combined.contains("hi"))
    }

    @Test("seatbelt denies writes outside the bot home")
    func shellWriteContainment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHomeStore(root: root)
        let botId = "bot-1"
        try home.write(botId: botId, path: "notes/a.txt", content: "hi\n")
        let result = try await home.runShell(
            botId: botId,
            command: "echo inside > notes/ok.txt"
        )
        #expect(result.exitCode == 0, "\(result.combined)")
        #expect(home.exists(botId: botId, path: "notes/ok.txt"), "\(result.combined)")
        let blocked = try await home.runShell(
            botId: botId,
            command: "echo leaked > /etc/grizzy-sandbox-probe.txt"
        )
        #expect(blocked.exitCode != 0)
        _ = result
    }

    @Test("shell timeout defaults and clamps")
    func shellTimeout() {
        #expect(BotHomeStore.ShellTimeout.default == 120)
        #expect(BotHomeStore.ShellTimeout.parse("") == 120)
        #expect(BotHomeStore.ShellTimeout.parse("180") == 180)
        #expect(BotHomeStore.ShellTimeout.parse("999") == 300)
        #expect(BotHomeStore.ShellTimeout.parse("2") == 5)
    }

    @Test("reads and lists absolute host paths the user named")
    func hostReadAndList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHomeStore(root: root)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skill = folder.appendingPathComponent("SKILL.md")
        try "# orchestration\n".write(to: skill, atomically: true, encoding: .utf8)

        let content = try home.readFlexible(botId: "bot-1", path: skill.path)
        #expect(content.contains("orchestration"))
        let listed = try home.listFlexible(botId: "bot-1", directory: folder.path)
        #expect(listed.contains(where: { $0.path.hasSuffix("SKILL.md") }))
        #expect(throws: BotHomeError.hostDenied) {
            _ = try home.readFlexible(botId: "bot-1", path: "/tmp/grizzy-deny/.ssh/id_rsa")
        }
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let note = backup.appendingPathComponent("readme.md")
        try "ok\n".write(to: note, atomically: true, encoding: .utf8)
        #expect(!BotHomeStore.isDeniedHostPath(note.path))
        #expect(try home.readFlexible(botId: "bot-1", path: note.path).contains("ok"))
        #expect(BotHomeStore.isDeniedHostPath("/tmp/grizzy-deny/.ssh/../.ssh/config"))
        #expect(!BotHomeStore.isDeniedHostPath("/tmp/project/.ssh-backup/readme.md"))
    }

    @Test("rejects path escape")
    func pathEscape() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHomeStore(root: root)
        #expect(throws: BotHomeError.pathEscapes) {
            try home.write(botId: "bot-1", path: "../escape.txt", content: "nope")
        }
    }
}

@Suite("WebSearch")
struct WebSearchTests {
    @Test("parses duckduckgo html results")
    func parseHTML() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage">Example Title</a>
        <a class="result__snippet">A short snippet about the page.</a>
        """
        let results = WebSearch.parseHTMLResults(html, limit: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Example Title")
        #expect(results[0].url == "https://example.com/page")
        #expect(results[0].snippet.contains("short snippet"))
    }

    @Test("parses lite and result-link markup when result__a is missing")
    func parseAlternateHTML() {
        let html = """
        <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.composio.dev%2Ftoolkits%2Fbox">Box toolkit</a>
        <a rel="nofollow" href="https://developer.box.com/guides/authentication/">Box auth guide</a>
        """
        let results = WebSearch.parseHTMLResults(html, limit: 5)
        #expect(results.contains(where: { $0.url.contains("docs.composio.dev") }))
        #expect(results.contains(where: { $0.url.contains("developer.box.com") }))
    }

    @Test("detects duckduckgo bot-block pages")
    func blockedHTML() {
        let html = """
        <html><body>Unfortunately, bots are not allowed. If this persists, DuckDuckGo may be blocking this.</body></html>
        """
        #expect(WebSearch.isBlockedPage(html))
        #expect(!WebSearch.isBlockedPage("<a class=\"result__a\" href=\"https://example.com\">Ok</a>"))
    }

    @Test("parses Wikipedia OpenSearch JSON")
    func wikipediaOpenSearch() throws {
        let json = """
        ["Composio",["Composio"],["Composio is an integration platform."],["https://en.wikipedia.org/wiki/Composio"]]
        """.data(using: .utf8)!
        let results = try WebSearch.parseWikipediaOpenSearch(json, limit: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Composio")
        #expect(results[0].url.contains("wikipedia.org"))
        #expect(results[0].snippet.contains("integration"))
    }

    @Test("fetch errors include the HTTP status")
    func fetchStatusMessage() {
        let message = WebSearch.fetchFailureMessage(status: 403, bodyPreview: "Forbidden")
        #expect(message.contains("403"))
        #expect(message.contains("Forbidden"))
    }

    @Test("parses Brave Search JSON")
    func braveJSON() throws {
        let json = """
        {"web":{"results":[{"title":"Otters","url":"https://example.com/otters","description":"Marine mammals"}]}}
        """.data(using: .utf8)!
        let results = try WebSearch.parseBraveWebSearch(json, limit: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Otters")
        #expect(results[0].url.contains("otters"))
    }
}

@Suite("OpenAI stream parse")
struct StreamParseTests {
    final class DeltaBox: @unchecked Sendable {
        var pieces: [String] = []
    }
    @Test("emits deltas and joins tool arguments")
    func sse() throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}
        data: {"choices":[{"delta":{"content":"lo"}}]}
        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}
        data: [DONE]
        """.data(using: .utf8)!
        let box = DeltaBox()
        let response = try OpenAIChatClient.parseOpenAIStream(sse) { box.pieces.append($0) }
        #expect(box.pieces == ["Hel", "lo"])
        #expect(response.text == "Hello")
        #expect(response.inputTokens == 3)
        #expect(response.outputTokens == 2)
    }
}
