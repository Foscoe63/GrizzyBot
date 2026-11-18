import Foundation
import GrizzyBotCore
import Testing

@Suite("Gateway protocols")
struct GatewayProtocolsTests {
    @Test("anthropic: system and block content become chat messages")
    func anthropic() {
        let json: [String: Any] = [
            "model": "grizzybot/ada", "system": "Be brief.",
            "messages": [["role": "user", "content": [["type": "text", "text": "hi"], ["type": "image"]]]],
        ]
        let p = GatewayProtocols.parseAnthropic(json)
        #expect(p.messages == [["role": "system", "content": "Be brief."], ["role": "user", "content": "hi"]])
        let reply = GatewayProtocols.anthropicReply("hello", model: "m")
        #expect(reply["type"] as? String == "message")
        #expect(((reply["content"] as? [[String: Any]])?.first?["text"] as? String) == "hello")
    }

    @Test("responses: string and item input")
    func responses() {
        #expect(GatewayProtocols.parseResponses(["input": "hi", "instructions": "x"]).messages.count == 2)
        let items: [String: Any] = ["input": [["role": "developer", "content": [["type": "input_text", "text": "rule"]]], ["role": "user", "content": "go"]]]
        #expect(GatewayProtocols.parseResponses(items).messages.first?["role"] == "system")
        let out = GatewayProtocols.responsesReply("done", model: "m")
        #expect(out["status"] as? String == "completed")
    }

    @Test("ollama and agent run shapes")
    func ollamaAndRun() {
        let p = GatewayProtocols.parseOllama(["model": "m", "messages": [["role": "user", "content": "hey"]]])
        #expect(p.messages.count == 1)
        #expect(GatewayProtocols.ollamaReply("yo", model: "m")["done"] as? Bool == true)
        #expect(GatewayProtocols.agentRunBotId(path: "/agents/bot-1/run") == "bot-1")
        #expect(GatewayProtocols.agentRunBotId(path: "/agents/run") == nil)
        #expect(GatewayProtocols.agentRunPrompt(["prompt": "do it"]) == "do it")
        let sse = GatewayProtocols.sse(reply: "ok")
        #expect(sse.hasPrefix("data: {") && sse.hasSuffix("data: [DONE]\n\n"))
    }
}

@Suite("Gateway streaming")
struct GatewayStreamingTests {
    @Test("each format frames start, pieces and end")
    func framing() {
        let f = GatewayProtocols.self
        let openAI = f.streamStart(.openAI, model: "m", id: "i") + f.streamDelta(.openAI, text: "Hi", model: "m", id: "i") + f.streamEnd(.openAI, model: "m", id: "i", fullText: "Hi")
        #expect(openAI.contains("\"content\":\"Hi\""))
        #expect(openAI.hasSuffix("data: [DONE]\n\n"))
        let anthropic = f.streamStart(.anthropic, model: "m", id: "i") + f.streamDelta(.anthropic, text: "Hi", model: "m", id: "i") + f.streamEnd(.anthropic, model: "m", id: "i", fullText: "Hi")
        #expect(anthropic.contains("event: content_block_delta"))
        #expect(anthropic.contains("\"text_delta\""))
        #expect(anthropic.hasSuffix("\n\n") && anthropic.contains("event: message_stop"))
        let ollama = f.streamDelta(.ollama, text: "Hi", model: "m", id: "i") + f.streamEnd(.ollama, model: "m", id: "i", fullText: "Hi")
        let lines = ollama.split(separator: "\n")
        #expect(lines.count == 2 && lines[1].contains("\"done\":true"))
        #expect(f.streamEnd(.responses, model: "m", id: "i", fullText: "Hi").contains("response.completed"))
    }

    @Test("streaming is asked for the way each API asks for it")
    func wants() {
        #expect(GatewayProtocols.wantsStream(.openAI, json: [:]) == false)
        #expect(GatewayProtocols.wantsStream(.openAI, json: ["stream": true]))
        #expect(GatewayProtocols.wantsStream(.ollama, json: [:]))
        #expect(GatewayProtocols.wantsStream(.ollama, json: ["stream": false]) == false)
        #expect(GatewayProtocols.wantsStream(.agentRun, json: [:]))
    }

    @Test("a live request gets the pieces as they are produced, in the OpenAI format")
    func liveOpenAI() async throws {
        let port = 18_000 + Int.random(in: 0..<1000)
        let gateway = LocalOpenAIGateway.shared
        await gateway.configure(settings: .init(enabled: true, port: port, apiKey: "", defaultBotId: "b"), bots: [(id: "b", name: "B")], handler: { _, _, _, onDelta in
            onDelta("Hel"); onDelta("lo")
            return "Hello"
        })
        await gateway.restart()
        defer { Task { await gateway.stop() } }
        try await Task.sleep(for: .milliseconds(300))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"grizzybot/b","stream":true,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        #expect(text.contains("\"content\":\"Hel\"") && text.contains("\"content\":\"lo\""))
        #expect(text.contains("\"finish_reason\":\"stop\"") && text.hasSuffix("data: [DONE]\n\n"))
        // Non-streaming still returns the whole reply.
        request.httpBody = Data(#"{"model":"grizzybot/b","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let (whole, _) = try await URLSession.shared.data(for: request)
        #expect(String(decoding: whole, as: UTF8.self).contains("\"content\":\"Hello\""))
    }
}
