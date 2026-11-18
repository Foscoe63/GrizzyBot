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
