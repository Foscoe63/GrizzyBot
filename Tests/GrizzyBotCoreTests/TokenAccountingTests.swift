import Foundation
import GrizzyBotCore
import Testing

@Suite("TokenAccounting")
struct TokenAccountingTests {
    @Test("empty draft is zero; short text is at least one token")
    func estimate() {
        #expect(TokenAccounting.estimate("") == 0)
        #expect(TokenAccounting.estimate("   ") == 0)
        #expect(TokenAccounting.estimate("hi") == 1)
        #expect(TokenAccounting.estimate(String(repeating: "a", count: 8)) == 2)
        #expect(TokenAccounting.estimate(String(repeating: "a", count: 9)) == 3)
    }

    @Test("live draft wins over last billed prompt")
    func displayedPrompt() {
        #expect(TokenAccounting.displayedPrompt(draft: "", lastBilledPrompt: 2048) == 2048)
        #expect(TokenAccounting.displayedPrompt(draft: "hello", lastBilledPrompt: 2048) == 2)
        #expect(TokenAccounting.displayedPrompt(draft: "  ", lastBilledPrompt: 0) == 0)
    }

    @Test("grouped integers use locale separators")
    func grouped() {
        let formatted = TokenAccounting.grouped(12401)
        #expect(formatted.contains("12"))
        #expect(formatted.contains("401"))
    }

    @Test("legacy usage JSON without promptTokens still decodes")
    func legacyUsageRecord() throws {
        struct Legacy: Codable {
            var id: String
            var provider: String
            var model: String
            var inputTokens: Int
            var outputTokens: Int
            var createdAt: Date
        }
        let data = try JSONEncoder().encode(
            Legacy(
                id: "u1",
                provider: "p",
                model: "m",
                inputTokens: 10,
                outputTokens: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let record = try JSONDecoder().decode(UsageRecord.self, from: data)
        #expect(record.promptTokens == nil)
        #expect(record.billedPromptTokens == 10)
        #expect(record.inputTokens == 10)
        #expect(record.outputTokens == 2)
    }
}
