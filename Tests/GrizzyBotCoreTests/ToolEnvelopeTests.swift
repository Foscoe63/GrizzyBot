import Foundation
import GrizzyBotCore
import Testing

@Suite("Tool envelope")
struct ToolEnvelopeTests {
    @Test("failure round-trips with kind and retryable")
    func roundTrip() {
        let text = ToolEnvelope.failure(kind: .invalidArgs, message: "Missing path", tool: "read_file", field: "path")
        let parsed = ToolEnvelope.parseFailure(text)
        #expect(parsed == ToolFailure(kind: .invalidArgs, retryable: true))
        #expect(ToolEnvelope.parseFailure(ToolEnvelope.success(text: "hi")) == nil)
        #expect(ToolEnvelope.isError(text))
    }

    @Test("plain-text failures are classified; ordinary output is not")
    func classify() {
        #expect(ToolEnvelope.classify(output: "shell did not respond within 330s and was abandoned")?.kind == .timeout)
        #expect(ToolEnvelope.classify(output: "Blocked: this call contained a key")?.kind == .blocked)
        #expect(ToolEnvelope.classify(output: "No such file or directory: a.txt")?.kind == .notFound)
        #expect(ToolEnvelope.classify(output: "Weather in Paris is mild; museum opens at nine.") == nil)
    }

    @Test("a call that keeps failing is told to stop")
    func repeatedFailure() {
        let guardian = ToolRetryGuard()
        var hint: String?
        for _ in 0..<ToolRetryGuard.repeatLimit {
            hint = guardian.note(run: "r", tool: "shell", arguments: "{}", output: "Error: command failed")
        }
        #expect(hint?.contains("Stop repeating") == true)
        // A success clears the streak.
        #expect(guardian.note(run: "r", tool: "shell", arguments: "{}", output: "ok done") == nil)
        #expect(guardian.note(run: "r", tool: "shell", arguments: "{}", output: "Error: failed") == nil)
    }
}
