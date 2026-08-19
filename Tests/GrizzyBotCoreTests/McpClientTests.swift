import Foundation
import GrizzyBotCore
import Testing

@Suite("McpClient")
struct McpClientTests {
    @Test("mcp_call flattens top-level path and content")
    func mcpCallArgs() {
        let nested = McpCallArguments.resolve([
            "server": .string("obsidian"),
            "tool": .string("write_note"),
            "arguments": .object([
                "filename": .string("a.md"),
                "content": .string("hello"),
            ]),
        ])
        #expect(nested["filename"] == .string("a.md"))
        #expect(nested["content"] == .string("hello"))
        #expect(nested["server"] == nil)

        let flat = McpCallArguments.resolve([
            "server": .string("obsidian"),
            "tool": .string("write_note"),
            "path": .string("Inbox/a.md"),
            "content": .string("# hi"),
        ])
        #expect(flat["path"] == .string("Inbox/a.md"))
        #expect(flat["content"] == .string("# hi"))
    }

    @Test("formatToolList includes required argument names")
    func formatToolList() {
        let tools = [
            McpToolInfo(
                name: "obsidian_append_content",
                description: "Append to a note",
                inputSchema: [
                    "type": AnyCodableMCP("object"),
                    "properties": AnyCodableMCP([
                        "filepath": ["type": "string"],
                        "content": ["type": "string"],
                    ] as [String: Any]),
                    "required": AnyCodableMCP(["filepath", "content"]),
                ]
            ),
        ]
        let text = McpClient.formatToolList(tools)
        #expect(text.contains("obsidian_append_content"))
        #expect(text.contains("filepath"))
        #expect(text.contains("content"))
        #expect(text.contains("required"))
    }
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

    @Test("stdio PATH prepends Homebrew even when the process PATH is GUI-short")
    func stdioPath() {
        let path = McpClient.stdioPATH(
            existing: "/usr/bin:/bin",
            home: "/Users/demo",
            exists: { $0 == "/opt/homebrew/bin" || $0 == "/Users/demo/.local/bin" }
        )
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/Users/demo/.local/bin"))
        #expect(path.contains("/usr/bin"))
        #expect(path.hasPrefix("/opt/homebrew/bin") || path.hasPrefix("/Users/demo/.local/bin"))
    }

    @Test("stdio extract reads newline and Content-Length frames")
    func stdioFrames() {
        var newline = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8) + Data([0x0A])
        let nl = McpClient.extractStdioMessages(from: &newline)
        #expect(nl.count == 1)
        #expect(newline.isEmpty)

        let body = #"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#
        var framed = Data("Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        let cl = McpClient.extractStdioMessages(from: &framed)
        #expect(cl.count == 1)
        #expect(framed.isEmpty)
    }

    @Test("stdio crash includes stderr and exit status")
    func stdioCrashSurfacesStderr() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return }

        let script = """
        import sys
        sys.stderr.write("npx: command not found\\n")
        sys.stderr.flush()
        sys.exit(127)
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grizzy-mcp-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("die.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let server = McpServer(
            name: "dead",
            transport: .stdio,
            command: "/usr/bin/python3",
            args: [scriptURL.path]
        )
        do {
            _ = try await McpClient.listTools(server: server, timeout: 5)
            Issue.record("expected the dying MCP process to throw")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("127") || text.lowercased().contains("exited"))
            #expect(text.contains("npx: command not found"))
            #expect(!text.contains("closed stdout"))
        }
    }
}
