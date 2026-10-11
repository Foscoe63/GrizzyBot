import Foundation
import GrizzyBotCore
import Testing

private final class MockBackend: ControlPlaneBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    var sentMessages: [String] { lock.withLock { sent } }

    func listBots() async -> [ControlPlaneBot] { [ControlPlaneBot(id: "b1", name: "Ada", title: "coder", status: "idle")] }
    func status(bot: String) async -> String? { bot == "Ada" ? "Ada: idle" : nil }
    func recentMessages(bot: String, limit: Int) async -> [String]? { bot == "Ada" ? ["[you] hi", "[Ada] hello"] : nil }
    func search(query: String, bot: String?) async -> [String] { query == "pricing" ? ["Ada:\nwe chose $9"] : [] }
    func send(bot: String, text: String, waitSeconds: Int) async -> String {
        lock.withLock { sent.append("\(bot):\(text):\(waitSeconds)") }
        return "Sent to Ada."
    }
    func interrupt(bot: String) async -> String { "Stopped Ada." }
    func setModel(bot: String, provider: String, model: String) async -> String { "ok" }
}

@Suite("Control plane")
struct ControlPlaneTests {
    private func rpc(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { object["id"] = id }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func text(_ reply: [String: Any]?) -> String {
        let result = reply?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @Test("initialize announces tools and nothing else")
    func initialize() async throws {
        let mcp = ControlPlaneMCP(backend: MockBackend())
        let reply = try #require(await mcp.handle(rpc("initialize")))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == ControlPlaneMCP.protocolVersion)
        let caps = try #require(result["capabilities"] as? [String: Any])
        #expect(Set(caps.keys) == ["tools"])
    }

    @Test("the tool list is exactly the bounded set — no approvals, deletion, credentials, settings or computer")
    func boundary() async throws {
        let mcp = ControlPlaneMCP(backend: MockBackend())
        let reply = try #require(await mcp.handle(rpc("tools/list")))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(names) == Set(ControlPlaneMCP.toolNames))
        for forbidden in ["approv", "delete", "credential", "secret", "key", "setting", "computer", "shell"] {
            #expect(!names.contains { $0.contains(forbidden) }, "\(forbidden)")
        }
        for tool in tools { #expect(tool["inputSchema"] != nil) }
    }

    @Test("tools run against the backend")
    func calls() async throws {
        let backend = MockBackend()
        let mcp = ControlPlaneMCP(backend: backend)
        #expect(text(await mcp.handle(rpc("tools/call", ["name": "grizzybot_list_bots"]))).contains("Ada — coder [idle]"))
        #expect(text(await mcp.handle(rpc("tools/call", ["name": "grizzybot_read_chat", "arguments": ["bot": "Ada"]]))).contains("[Ada] hello"))
        #expect(text(await mcp.handle(rpc("tools/call", ["name": "grizzybot_search_chats", "arguments": ["query": "pricing"]]))).contains("$9"))
        #expect(text(await mcp.handle(rpc("tools/call", ["name": "grizzybot_send_message", "arguments": ["bot": "Ada", "text": "ship it", "wait_seconds": 300]]))) == "Sent to Ada.")
        #expect(backend.sentMessages == ["Ada:ship it:120"]) // wait is capped
    }

    @Test("missing arguments, unknown bots and unknown tools are errors, not crashes")
    func errors() async throws {
        let mcp = ControlPlaneMCP(backend: MockBackend())
        let missing = try #require(await mcp.handle(rpc("tools/call", ["name": "grizzybot_send_message", "arguments": ["bot": "Ada"]])))
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknownBot = try #require(await mcp.handle(rpc("tools/call", ["name": "grizzybot_bot_status", "arguments": ["bot": "Nobody"]])))
        #expect((unknownBot["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknownTool = try #require(await mcp.handle(rpc("tools/call", ["name": "delete_everything"])))
        #expect((unknownTool["result"] as? [String: Any])?["isError"] as? Bool == true)
        let method = try #require(await mcp.handle(rpc("resources/list")))
        #expect((method["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = try #require(await mcp.handle(Data("not json".utf8)))
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test("notifications get no reply")
    func notification() async {
        let mcp = ControlPlaneMCP(backend: MockBackend())
        #expect(await mcp.handle(rpc("notifications/initialized", id: nil)) == nil)
    }

    @Test("the HTTP route demands the bearer token")
    func auth() async {
        let server = ControlPlaneServer()
        let body = rpc("tools/list")
        func request(_ header: String?) -> HTTPRequestParser.Request {
            HTTPRequestParser.Request(method: "POST", path: "/mcp", headers: header.map { ["authorization": $0] } ?? [:], body: body)
        }
        let none = await server.routeForTesting(request(nil), token: "s3cret", backend: MockBackend())
        #expect(none.0 == 401)
        let wrong = await server.routeForTesting(request("Bearer nope"), token: "s3cret", backend: MockBackend())
        #expect(wrong.0 == 401)
        let right = await server.routeForTesting(request("Bearer s3cret"), token: "s3cret", backend: MockBackend())
        #expect(right.0 == 200)
        let health = await server.routeForTesting(HTTPRequestParser.Request(method: "GET", path: "/health"), token: "s3cret", backend: MockBackend())
        #expect(health.0 == 200)
        let elsewhere = await server.routeForTesting(HTTPRequestParser.Request(method: "POST", path: "/admin", headers: ["authorization": "Bearer s3cret"]), token: "s3cret", backend: MockBackend())
        #expect(elsewhere.0 == 404)
    }
}

@Suite("Tracing")
struct TracingTests {
    @Test("ids are the right width and stable per run")
    func ids() {
        let trace = Tracing.traceId(forRun: "run-1")
        #expect(trace.count == 32 && trace == Tracing.traceId(forRun: "run-1") && trace != Tracing.traceId(forRun: "run-2"))
        #expect(Tracing.runSpanId(forRun: "run-1").count == 16)
        #expect(Tracing.newSpanId().count == 16)
    }

    @Test("the OTLP body carries timings and counts, with the run as parent of its tool spans")
    func payload() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let parent = Tracing.runSpanId(forRun: "r")
        let spans = [
            TraceSpan(traceId: Tracing.traceId(forRun: "r"), spanId: parent, name: "run Ada", start: t0, end: t0.addingTimeInterval(2), attributes: ["model": "x/y"], counts: ["steps": 3]),
            TraceSpan(traceId: Tracing.traceId(forRun: "r"), spanId: "0123456789abcdef", parentSpanId: parent, name: "tool web_fetch", start: t0, end: t0.addingTimeInterval(1), ok: false),
        ]
        let data = Tracing.otlpPayload(spans)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"service.name\""))
        #expect(text.contains("\"parentSpanId\":\"\(parent)\""))
        #expect(text.contains("\"startTimeUnixNano\":\"1800000000000000000\""))
        #expect(text.contains("\"intValue\":\"3\""))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["resourceSpans"] as? [Any])?.count == 1)
        // Nothing that could hold a prompt or an argument.
        #expect(!text.contains("prompt") && !text.contains("arguments"))
    }

    @Test("endpoints are normalised to the traces path")
    func urls() {
        #expect(Tracing.tracesURL(from: "http://localhost:4318")?.absoluteString == "http://localhost:4318/v1/traces")
        #expect(Tracing.tracesURL(from: "http://localhost:4318/v1/traces")?.absoluteString == "http://localhost:4318/v1/traces")
        #expect(Tracing.tracesURL(from: "") == nil)
        #expect(Tracing.tracesURL(from: "file:///etc/passwd") == nil)
    }
}

@Suite("Control plane over a real socket")
struct ControlPlaneSocketTests {
    @Test("an MCP client can initialise and list tools over loopback with the token")
    func live() async throws {
        let server = ControlPlaneServer()
        let port = Int.random(in: 40_001...60_000)
        try await server.start(port: port, token: "tok", backend: MockBackend())
        defer { Task { await server.stop() } }
        try await Task.sleep(nanoseconds: 300_000_000)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("grizzybot_send_message"))
        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)
    }
}
