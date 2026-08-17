import Foundation
import GrizzyBotCore
import Testing

@Suite("McpClient")
struct McpClientTests {
    @Test("selects tool by name in prompt")
    func selectTool() {
        let tools = [
            McpToolInfo(name: "notes.write", description: "write"),
            McpToolInfo(name: "search", description: "search"),
        ]
        #expect(McpClient.selectTool(from: tools, prompt: "please use notes.write now").name == "notes.write")
        #expect(McpClient.selectTool(from: tools, prompt: "look something up").name == "search")
    }

    @Test("builds args from schema preferred keys")
    func buildArgs() {
        let tool = McpToolInfo(
            name: "search",
            inputSchema: [
                "type": AnyCodableMCP("object"),
                "properties": AnyCodableMCP([
                    "query": ["type": "string"],
                    "limit": ["type": "number"],
                ] as [String: Any]),
                "required": AnyCodableMCP(["query"]),
            ]
        )
        let args = McpClient.buildArguments(for: tool, prompt: "otters")
        #expect(args["query"] as? String == "otters")
    }

    @Test("parses SSE data events")
    func parseSSE() throws {
        let text = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}

        """
        let events = McpClient.parseSSEDataEvents(text)
        #expect(events.count == 1)
        let obj = try #require(JSONSerialization.jsonObject(with: events[0]) as? [String: Any])
        let result = try #require(obj["result"] as? [String: Any])
        #expect(result["ok"] as? Bool == true)
    }

    @Test("stdio echo server round-trip")
    func stdioRoundTrip() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return // skip when python3 is unavailable
        }

        let script = """
        #!/usr/bin/env python3
        import sys, json

        def read():
            line = sys.stdin.readline()
            if not line:
                return None
            return json.loads(line)

        def write(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        while True:
            msg = read()
            if msg is None:
                break
            method = msg.get("method")
            if method == "initialize":
                write({
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "result": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "echo", "version": "1.0.0"},
                    },
                })
            elif method == "notifications/initialized":
                pass
            elif method == "tools/list":
                write({
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "result": {
                        "tools": [{
                            "name": "echo",
                            "description": "Echo text",
                            "inputSchema": {
                                "type": "object",
                                "properties": {"text": {"type": "string"}},
                                "required": ["text"],
                            },
                        }]
                    },
                })
            elif method == "tools/call":
                args = (msg.get("params") or {}).get("arguments") or {}
                write({
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "result": {
                        "content": [{"type": "text", "text": args.get("text", "")}],
                    },
                })
            else:
                write({
                    "jsonrpc": "2.0",
                    "id": msg.get("id"),
                    "error": {"code": -32601, "message": "unknown"},
                })
        """

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grizzy-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("echo_mcp.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let server = McpServer(
            name: "echo",
            transport: .stdio,
            command: "/usr/bin/python3",
            args: [scriptURL.path]
        )
        let result = try await McpClient.invoke(server: server, prompt: "hello from test")
        #expect(result.toolName == "echo")
        #expect(result.text.contains("hello from test"))
        #expect(result.isError == false)
    }
}
