import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct McpHealthTests {
    @Test func failuresCountAndSuccessResets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-health-\(UUID().uuidString).json")
        let book = McpHealthBook()
        book.attach(to: url)
        struct Boom: Error, LocalizedError { var errorDescription: String? { "connect to /tmp/x.sock failed after 30 s" } }
        for _ in 0..<3 { book.recordFailure(serverId: "s", error: Boom()) }
        let h = try #require(book.health(for: "s"))
        #expect(h.isDegraded && h.consecutiveFailures == 3)
        #expect(h.summary.contains("3 failed in a row"))
        #expect(!(h.lastReason ?? "").contains("/tmp"))

        let reloaded = McpHealthBook()
        reloaded.attach(to: url)
        #expect(reloaded.health(for: "s")?.consecutiveFailures == 3)

        book.recordSuccess(serverId: "s")
        #expect(book.health(for: "s")?.isDegraded == false)
    }

    @Test func capIsSixteenMegabytes() {
        #expect(McpLimits.maxResponseBytes == 16 * 1024 * 1024)
    }
}
