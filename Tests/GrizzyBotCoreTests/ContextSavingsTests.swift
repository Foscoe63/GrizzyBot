import Foundation
import GrizzyBotCore
import Testing

@Suite("Context savings")
struct ContextSavingsTests {
    private let endpoint = ModelEndpoint(
        provider: "openrouter", model: "test", baseURL: "https://example.com/v1", apiKey: "k"
    )

    private func bigJSON(items: Int) -> String {
        let rows = (0..<items).map { #"{"id":\#($0),"name":"item-\#($0)","note":"\#(String(repeating: "x", count: 80))"}"# }
        return "{\"total\":\(items),\"items\":[" + rows.joined(separator: ",") + "]}"
    }

    @Test("JSON is sampled, not cut mid-structure, and the original is recoverable")
    func jsonCompression() throws {
        let store = ResultStore()
        let raw = bigJSON(items: 200)
        let shown = try #require(store.stash(tool: "mcp_call", raw: raw))
        #expect(shown.count < raw.count / 4)
        #expect(shown.contains("\"total\":200"))
        #expect(shown.contains("more items (total 200)"))
        #expect(shown.contains("[stored as r1:"))
        let found = store.recall(arguments: #"{"id":"r1","query":"item-173"}"#)
        #expect(found.contains("item-173"))
    }

    @Test("logs keep errors from the middle")
    func logCompression() throws {
        let store = ResultStore()
        var lines = (0..<400).map { "2026-10-23 12:00:\($0 % 60) INFO worker tick \($0)" }
        lines[210] = "2026-10-23 12:03:30 ERROR payment failed: card declined"
        let shown = try #require(store.stash(tool: "shell", raw: lines.joined(separator: "\n")))
        #expect(shown.contains("card declined"))
        #expect(shown.contains("L211:"))
        #expect(!shown.contains("worker tick 150"))
    }

    @Test("code keeps declarations and line numbers")
    func codeCompression() throws {
        let store = ResultStore()
        var lines: [String] = []
        for i in 0..<120 {
            lines.append("    let value\(i) = compute(\(i)) // filler filler filler filler")
            if i % 30 == 0 { lines.append("func handler\(i)() {") }
        }
        let shown = try #require(store.stash(tool: "read_file", raw: lines.joined(separator: "\n")))
        #expect(shown.contains("func handler60()"))
        let slice = store.recall(arguments: #"{"id":"r1","line":2,"lines":3}"#)
        #expect(slice.contains("lines 2-4 of"))
    }

    @Test("small output is left alone and unknown ids are explained")
    func smallAndUnknown() {
        let store = ResultStore()
        #expect(store.stash(tool: "shell", raw: "ok") == nil)
        #expect(store.recall(arguments: #"{"id":"r9"}"#).contains("Nothing is stored"))
        store.put(tool: "shell", text: "a\nb")
        #expect(store.recall(arguments: #"{"id":"r9"}"#).contains("No stored output r9"))
    }

    @Test("digest records what was dropped, and survives a second compaction")
    func digest() {
        var messages: [ChatMessage] = [.system("sys")]
        for i in 0..<10 {
            messages.append(.user("please do task \(i)"))
            messages.append(ChatMessage(role: "assistant", toolCalls: [LLMToolCall(id: "c\(i)", name: "shell", arguments: "{\"cmd\":\"step\(i)\"}")]))
            messages.append(.tool(id: "c\(i)", content: i == 3 ? "Tool error: boom" : "fine \(i)"))
        }
        let packed = ContextCompactor.compact(messages, budget: 10)
        let note = packed.messages.first { ($0.content ?? "").hasPrefix(ContextDigest.prefix) }?.content ?? ""
        #expect(note.contains("compacted"))
        #expect(note.contains("task 0"))
        #expect(note.contains("shell("))
        #expect(note.contains("ERROR"))
        let again = ContextCompactor.compact(packed.messages + messages, budget: 10)
        let note2 = again.messages.first { ($0.content ?? "").hasPrefix(ContextDigest.prefix) }?.content ?? ""
        #expect(note2.contains("task 0"))
    }

    @Test("loop compresses a big output, serves recall, and reports savings")
    func loopEndToEnd() async throws {
        let raw = bigJSON(items: 300)
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "a", name: "fetch_data", arguments: "{}")]),
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "b", name: "recall_result", arguments: #"{"query":"item-250"}"#)]),
            ChatCompletionResponse(text: "found it"),
        ])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: endpoint, botName: "Scout", prompt: "go", tools: [])
        ) { name, _ in
            AgentToolCallResult(output: name == "fetch_data" ? raw : "unexpected \(name)")
        }
        #expect(result.text == "found it")
        #expect(client.requests[0].tools.contains { $0.function.name == "recall_result" })
        let second = client.requests[1].messages.last { $0.role == "tool" }?.content ?? ""
        #expect(second.contains("[stored as r1:"))
        let third = client.requests[2].messages.last { $0.role == "tool" }?.content ?? ""
        #expect(third.contains("item-250"))
        #expect(result.savings.compressedOutputs == 1)
        #expect(result.savings.recalls == 1)
        #expect(result.savings.compressedCharsSaved > raw.count / 2)
        #expect(!result.savings.summaryLine.isEmpty)
        // Saved transcript must not point at a store that no longer exists.
        #expect(!result.messages.contains { ($0.content ?? "").contains("stored as r1") })
    }

    @Test("pinned facts stay in the transcript and carry to the next turn")
    func pinning() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "a", name: "pin_fact", arguments: #"{"fact":"Deploy target is staging-2"}"#)]),
            ChatCompletionResponse(text: "ok"),
        ])
        let result = try await AgentLoop.run(
            client: client,
            request: AgentLoopRequest(endpoint: endpoint, botName: "Scout", prompt: "go", tools: [])
        ) { _, _ in AgentToolCallResult(output: "unused") }
        let seen = client.requests[1].messages.filter(PinnedFacts.isPinMessage)
        #expect(seen.count == 1)
        #expect(seen.first?.content?.contains("staging-2") == true)
        #expect(result.savings.pinnedFacts == 1)
        #expect(PinnedFacts.extract(from: result.messages) == ["Deploy target is staging-2"])
    }

    @Test("switching the feature off restores the old behaviour")
    func disabled() async throws {
        let client = QueueChatClient([
            ChatCompletionResponse(toolCalls: [LLMToolCall(id: "a", name: "fetch_data", arguments: "{}")]),
            ChatCompletionResponse(text: "done"),
        ])
        var request = AgentLoopRequest(endpoint: endpoint, botName: "Scout", prompt: "go", tools: [])
        request.contextSavings = false
        let result = try await AgentLoop.run(client: client, request: request) { _, _ in
            AgentToolCallResult(output: String(repeating: "word ", count: 2_000))
        }
        #expect(!client.requests[0].tools.contains { $0.function.name == "recall_result" })
        #expect(result.savings.isEmpty)
        #expect((client.requests[1].messages.last { $0.role == "tool" }?.content ?? "").contains("summarized"))
    }
}
