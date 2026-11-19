import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Prompt version")
struct PromptVersionTests {
    @Test("is stable and well formed")
    func stable() {
        #expect(PromptVersion.compute() == PromptVersion.compute())
        #expect(PromptVersion.current.count == 12)
        #expect(PromptVersion.current.allSatisfy { $0.isHexDigit })
    }

    @Test("changes when a rendered prompt changes")
    func sensitive() {
        let base = AgentPrompts.continueAfterLength(tail: "a")
        #expect(base != AgentPrompts.continueAfterLength(tail: "b"))
    }
}
