import Foundation
import GrizzyBotCore
import Testing

@Suite("MCP protocol")
struct McpProtocolTests {
    @Test("tool results split text, images, resources and links")
    func toolResultContent() {
        let out = McpClient.parseToolResult([
            "content": [
                ["type": "text", "text": "hello"],
                ["type": "image", "data": "QUJD", "mimeType": "image/png"],
                ["type": "resource", "resource": ["uri": "file:///a.txt", "text": "body"]],
                ["type": "resource_link", "name": "doc", "uri": "https://x/doc"],
                ["type": "audio", "data": "AAAA", "mimeType": "audio/wav"],
            ],
        ])
        #expect(out.images == [McpImagePart(base64: "QUJD", mimeType: "image/png")])
        #expect(out.text.contains("hello"))
        #expect(out.text.contains("body"))
        #expect(out.text.contains("https://x/doc"))
        #expect(!out.text.contains("QUJD"))
        #expect(!out.text.contains("AAAA"))
    }

    @Test("tool annotations are read from tools/list")
    func annotations() {
        let tools = McpClient.parseToolList(["tools": [
            ["name": "read_it", "annotations": ["readOnlyHint": true]],
            ["name": "wipe", "annotations": ["destructiveHint": true]],
            ["name": "plain"],
        ]])
        #expect(tools[0].readOnlyHint == true)
        #expect(tools[1].destructiveHint == true)
        #expect(tools[2].readOnlyHint == nil && tools[2].destructiveHint == nil)
    }

    @Test("approval follows annotations, then the catalog's known write tools")
    func approval() {
        let server = McpServer(name: "mystery", transport: .stdio, command: "x")
        #expect(!McpCatalog.needsApproval(server: server, toolName: "t", listed: McpToolInfo(name: "t", readOnlyHint: true)))
        #expect(McpCatalog.needsApproval(server: server, toolName: "t", listed: McpToolInfo(name: "t", destructiveHint: true)))
        #expect(McpCatalog.needsApproval(server: server, toolName: "t", listed: McpToolInfo(name: "t", readOnlyHint: false)))
        #expect(!McpCatalog.needsApproval(server: server, toolName: "t", listed: McpToolInfo(name: "t")))
    }

    @Test("the server's ping and roots/list requests get answers")
    func serverRequests() {
        McpRoots.set(["/tmp/work"])
        #expect(McpClient.serverRequestResult(method: "ping")?.isEmpty == true)
        let roots = McpClient.serverRequestResult(method: "roots/list")?["roots"] as? [[String: Any]]
        #expect(roots?.first?["uri"] as? String == "file:///tmp/work")
        #expect(McpClient.serverRequestResult(method: "sampling/createMessage") == nil)
        McpRoots.set([])
    }

    @Test("stdio: paged tools/list, a colliding server ping, roots/list and image results")
    func stdioEndToEnd() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let script = """
        import sys, json
        def read():
            line = sys.stdin.readline()
            return json.loads(line) if line else None
        def write(o):
            sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        while True:
            msg = read()
            if msg is None: break
            m = msg.get("method")
            if m == "initialize":
                write({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"s","version":"1"}}})
            elif m == "tools/list":
                cursor = (msg.get("params") or {}).get("cursor")
                if not cursor:
                    # A server request whose id equals the id of our pending request.
                    write({"jsonrpc":"2.0","id":msg["id"],"method":"ping"})
                    reply = read()
                    assert reply.get("id") == msg["id"] and reply.get("result") == {}
                    write({"jsonrpc":"2.0","id":msg["id"],"result":{"tools":[{"name":"first","annotations":{"readOnlyHint":True}}],"nextCursor":"p2"}})
                else:
                    write({"jsonrpc":"2.0","id":msg["id"],"result":{"tools":[{"name":"second"}]}})
            elif m == "tools/call":
                write({"jsonrpc":"2.0","id":77,"method":"roots/list"})
                reply = read()
                uris = [r["uri"] for r in reply["result"]["roots"]]
                write({"jsonrpc":"2.0","id":msg["id"],"result":{"content":[
                    {"type":"text","text":"roots=" + ",".join(uris)},
                    {"type":"image","data":"QUJD","mimeType":"image/jpeg"}]}})
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grizzy-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("s.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let server = McpServer(name: "paged", transport: .stdio, command: "/usr/bin/python3", args: [scriptURL.path])

        let tools = try await McpClient.listTools(server: server)
        #expect(tools.map(\.name) == ["first", "second"])
        #expect(tools[0].readOnlyHint == true)

        McpRoots.set(["/tmp/granted"])
        defer { McpRoots.set([]) }
        let result = try await McpClient.call(server: server, toolName: "first")
        #expect(result.text.contains("roots=file:///tmp/granted"))
        #expect(result.images.first?.base64 == "QUJD")
        await McpSessionPool.shared.invalidate(server)
    }
}
