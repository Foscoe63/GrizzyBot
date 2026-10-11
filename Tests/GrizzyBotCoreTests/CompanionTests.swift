import Foundation
import GrizzyBotCore
import Testing

private final class CompanionMock: CompanionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String] = []
    private var sent: [String] = []
    var answered: [String] { lock.withLock { answers } }
    var sentTexts: [String] { lock.withLock { sent } }
    var pending: [CompanionApproval] = [
        CompanionApproval(botId: "b1", botName: "Ada", tool: "shell.exec", detail: "ls", answerableHere: true),
        CompanionApproval(botId: "b2", botName: "Grace", tool: "secret.request", detail: "KEY", answerableHere: false),
    ]

    func listBots() async -> [ControlPlaneBot] { [ControlPlaneBot(id: "b1", name: "Ada", title: "coder", status: "idle")] }
    func status(bot: String) async -> String? { "Ada: idle" }
    func recentMessages(bot: String, limit: Int) async -> [String]? { bot == "b1" ? ["[you] hi", "[Ada] hello"] : nil }
    func search(query: String, bot: String?) async -> [String] { [] }
    func send(bot: String, text: String, waitSeconds: Int) async -> String { lock.withLock { sent.append(text) }; return "Sent." }
    func interrupt(bot: String) async -> String { "Stopped." }
    func setModel(bot: String, provider: String, model: String) async -> String { "ok" }
    func pendingApprovals() async -> [CompanionApproval] { pending }
    func answerApproval(bot: String, allow: Bool) async -> String { lock.withLock { answers.append("\(bot):\(allow)") }; return "ok" }
}

@Suite("Phone companion")
struct CompanionTests {
    private func request(_ method: String, _ path: String, query: [String: String] = [:], token: String? = "tok", body: [String: Any]? = nil) -> HTTPRequestParser.Request {
        HTTPRequestParser.Request(
            method: method, path: path, query: query,
            headers: token.map { ["authorization": "Bearer \($0)"] } ?? [:],
            body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        )
    }

    private func object(_ reply: CompanionAPI.Reply) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any]) ?? [:]
    }

    @Test("the page is served without a token, with a locked-down policy and no external requests")
    func page() async {
        let server = CompanionServer()
        let reply = await server.routeForTesting(request("GET", "/", token: nil), token: "tok", backend: CompanionMock())
        #expect(reply.status == 200)
        let html = String(decoding: reply.body, as: UTF8.self)
        #expect(html.contains("GrizzyBot"))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(reply.headers["Content-Security-Policy"]?.contains("connect-src 'self'") == true)
    }

    @Test("the API needs the token")
    func auth() async {
        let server = CompanionServer()
        let no = await server.routeForTesting(request("GET", "/api/bots", token: nil), token: "tok", backend: CompanionMock())
        #expect(no.status == 401)
        let wrong = await server.routeForTesting(request("GET", "/api/bots", token: "nope"), token: "tok", backend: CompanionMock())
        #expect(wrong.status == 401)
        let yes = await server.routeForTesting(request("GET", "/api/bots"), token: "tok", backend: CompanionMock())
        #expect(yes.status == 200)
        #expect((object(yes)["bots"] as? [[String: Any]])?.first?["name"] as? String == "Ada")
    }

    @Test("five wrong tokens lock the API, even for the right one, until the minute passes")
    func lockout() async {
        let server = CompanionServer()
        let mock = CompanionMock()
        for _ in 0..<5 { _ = await server.routeForTesting(request("GET", "/api/bots", token: "bad"), token: "tok", backend: mock) }
        let locked = await server.routeForTesting(request("GET", "/api/bots"), token: "tok", backend: mock)
        #expect(locked.status == 429)
        let page = await server.routeForTesting(request("GET", "/", token: nil), token: "tok", backend: mock)
        #expect(page.status == 200)
    }

    @Test("chat, send, and stop work; an unknown bot is a 404")
    func chat() async {
        let server = CompanionServer()
        let mock = CompanionMock()
        let chat = await server.routeForTesting(request("GET", "/api/chat", query: ["bot": "b1"]), token: "tok", backend: mock)
        #expect((object(chat)["messages"] as? [String])?.last == "[Ada] hello")
        let missing = await server.routeForTesting(request("GET", "/api/chat", query: ["bot": "zzz"]), token: "tok", backend: mock)
        #expect(missing.status == 404)
        let send = await server.routeForTesting(request("POST", "/api/send", body: ["bot": "b1", "text": "  ship it "]), token: "tok", backend: mock)
        #expect(send.status == 200 && mock.sentTexts == ["ship it"])
        let empty = await server.routeForTesting(request("POST", "/api/send", body: ["bot": "b1", "text": " "]), token: "tok", backend: mock)
        #expect(empty.status == 400)
    }

    @Test("approvals can be allowed or denied from the phone, but never 'always', and never a secret")
    func approvals() async {
        let server = CompanionServer()
        let mock = CompanionMock()
        let list = await server.routeForTesting(request("GET", "/api/pending"), token: "tok", backend: mock)
        #expect((object(list)["pending"] as? [[String: Any]])?.count == 2)
        let always = await server.routeForTesting(request("POST", "/api/approve", body: ["bot": "b1", "decision": "always"]), token: "tok", backend: mock)
        #expect(always.status == 400)
        let ok = await server.routeForTesting(request("POST", "/api/approve", body: ["bot": "b1", "decision": "allow"]), token: "tok", backend: mock)
        #expect(ok.status == 200)
        let secret = await server.routeForTesting(request("POST", "/api/approve", body: ["bot": "b2", "decision": "allow"]), token: "tok", backend: mock)
        #expect(secret.status == 403)
        let deny = await server.routeForTesting(request("POST", "/api/approve", body: ["bot": "b2", "decision": "deny"]), token: "tok", backend: mock)
        #expect(deny.status == 200)
        let none = await server.routeForTesting(request("POST", "/api/approve", body: ["bot": "b9", "decision": "allow"]), token: "tok", backend: mock)
        #expect(none.status == 409)
        #expect(mock.answered == ["b1:true", "b2:false"])
    }

    @Test("nothing outside /api and the page is reachable")
    func scope() async {
        let server = CompanionServer()
        for path in ["/admin", "/api/settings", "/api/secrets", "/.env"] {
            let reply = await server.routeForTesting(request("GET", path), token: "tok", backend: CompanionMock())
            #expect(reply.status == 404, "\(path)")
        }
    }
}

@Suite("Companion over a real socket")
struct CompanionSocketTests {
    @Test("the listener serves the page and a token-checked API on loopback")
    func live() async throws {
        let server = CompanionServer()
        let port = Int.random(in: 20_000...40_000)
        try await server.start(port: port, allowNetwork: false, token: "tok", backend: CompanionMock())
        defer { Task { await server.stop() } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let (page, pageResponse) = try await URLSession.shared.data(from: base)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("GrizzyBot"))

        var denied = URLRequest(url: base.appendingPathComponent("api/bots"))
        denied.timeoutInterval = 5
        let (_, deniedResponse) = try await URLSession.shared.data(for: denied)
        #expect((deniedResponse as? HTTPURLResponse)?.statusCode == 401)

        var allowed = URLRequest(url: base.appendingPathComponent("api/bots"))
        allowed.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        let (body, allowedResponse) = try await URLSession.shared.data(for: allowed)
        #expect((allowedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Ada"))
    }
}
