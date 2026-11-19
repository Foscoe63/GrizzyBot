import Testing
import Foundation
@testable import GrizzyBotCore

@Suite(.serialized) struct McpGuardsTests {
    private let params: [String: Any] = [
        "message": "Which repo?",
        "requestedSchema": [
            "type": "object",
            "properties": ["repo": ["type": "string", "title": "Repo"], "count": ["type": "integer"], "dry": ["type": "boolean"]],
            "required": ["repo"],
        ],
    ]

    @Test func declinesWithoutHandler() async {
        McpElicitation.handler = nil
        #expect(McpElicitation.isEnabled == false)
        let r = await McpElicitation.respond(params: params)
        #expect(r["action"] as? String == "decline")
    }

    @Test func acceptConvertsTypes() async {
        McpElicitation.handler = { _, fields in
            #expect(fields.map(\.key) == ["count", "dry", "repo"])
            return .accept(["repo": "x/y", "count": "3", "dry": "yes"])
        }
        defer { McpElicitation.handler = nil }
        let r = await McpElicitation.respond(params: params)
        let c = r["content"] as? [String: Any]
        #expect(r["action"] as? String == "accept")
        #expect(c?["count"] as? Int == 3)
        #expect(c?["dry"] as? Bool == true)
        #expect(c?["repo"] as? String == "x/y")
    }

    @Test func capabilityAdvertisedOnlyWithHandler() {
        McpElicitation.handler = nil
        #expect(McpElicitation.isEnabled == false)
        McpElicitation.handler = { _, _ in .cancel }
        #expect(McpElicitation.isEnabled)
        McpElicitation.handler = nil
    }

    @Test func clipsHugeText() {
        let big = String(repeating: "a", count: McpResponseLimit.maxTextChars + 500)
        let out = McpClient.parseToolResult(["content": [["type": "text", "text": big]]])
        #expect(out.text.count < big.count)
        #expect(out.text.contains("tool result cut"))
        #expect(McpResponseLimit.exceeds(bytes: McpResponseLimit.maxBytes + 1))
    }
}
