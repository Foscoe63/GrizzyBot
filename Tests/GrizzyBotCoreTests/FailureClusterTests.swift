import Foundation
import Testing
@testable import GrizzyBotCore

@Suite struct FailureClusterTests {
    @Test func normalizeStripsVaryingParts() {
        let a = FailureSignature.normalize("Error: cannot open /Users/ed/work/a1.txt after 12 tries (id 3f2a9c1d-1111-2222-3333-444455556666)")
        let b = FailureSignature.normalize("Error: cannot open /Users/sam/other/b9.txt after 7 tries (id 00000000-aaaa-bbbb-cccc-ddddeeeeffff)")
        #expect(a == b)
        #expect(!a.contains("/users"))
        #expect(FailureSignature.normalize("fetch https://x.com/a?b=1 failed for bob@x.com") == "fetch <url> failed for <email>")
    }

    @Test func shellGroupsByExitAndKind() {
        #expect(FailureSignature.shell(exitCode: 127, output: "zsh: command not found: foo") == "shell exit 127: command not found")
        #expect(FailureSignature.shell(exitCode: 1, output: "Permission denied") == "shell exit 1: permission denied")
    }

    @Test func bookCountsAndStoresNoRawText() {
        var book = FailureClusterBook()
        let sig = FailureSignature.tool("web_fetch", error: "Error: 503 from https://a.com/x")
        book.record(signature: sig, botId: "a", fingerprint: "f1")
        book.record(signature: FailureSignature.tool("web_fetch", error: "Error: 503 from https://b.com/y"), botId: "b", fingerprint: "f2")
        #expect(book.clusters.count == 1)
        #expect(book.top().first?.count == 2)
        #expect(book.top().first?.fingerprints == ["f1", "f2"])
        #expect(!(book.top().first?.signature.contains("a.com") ?? true))
    }

    @Test func fingerprintChangesWithPromptOrTools() {
        let base = PromptFingerprint.compute(systemPrompt: "x", toolNames: ["a", "b"])
        #expect(base == PromptFingerprint.compute(systemPrompt: "x", toolNames: ["b", "a"]))
        #expect(base != PromptFingerprint.compute(systemPrompt: "y", toolNames: ["a", "b"]))
        #expect(base != PromptFingerprint.compute(systemPrompt: "x", toolNames: ["a"]))
    }
}
