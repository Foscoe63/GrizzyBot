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
}
