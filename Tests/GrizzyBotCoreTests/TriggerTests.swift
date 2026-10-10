import Foundation
import GrizzyBotCore
import Testing

@Suite("Routine events")
struct RoutineEventPureTests {
    @Test("heartbeat all-clear is recognised through markdown and punctuation")
    func heartbeatIdle() {
        #expect(HeartbeatPolicy.isIdle("HEARTBEAT_OK"))
        #expect(HeartbeatPolicy.isIdle("  **heartbeat_ok**.\n"))
        #expect(!HeartbeatPolicy.isIdle("HEARTBEAT_OK but the build is red"))
        #expect(!HeartbeatPolicy.isIdle("Build failed"))
        #expect(HeartbeatPolicy.prompt(checklist: "- inbox").contains("- inbox"))
    }

    @Test("continuity adds the previous report and bounds it")
    func continuity() {
        #expect(RoutineContinuity.compose(prompt: "p", previous: nil) == "p")
        #expect(RoutineContinuity.compose(prompt: "p", previous: "  ") == "p")
        let composed = RoutineContinuity.compose(prompt: "p", previous: "old news")
        #expect(composed.contains("old news"))
        #expect(composed.hasPrefix("p"))
        #expect(RoutineContinuity.bounded(String(repeating: "x", count: 9_000)).count < 4_100)
    }

    @Test("webhook payload is framed as untrusted data")
    func webhookPrompt() {
        let text = WebhookPrompt.compose(prompt: "triage", payload: "{\"a\":1}", source: "ci")
        #expect(text.contains("untrusted"))
        #expect(text.contains("{\"a\":1}"))
        #expect(WebhookPrompt.compose(prompt: "triage", payload: "  ", source: "ci") == "triage")
    }

    @Test("secret comparison")
    func secrets() {
        let secret = WebhookSecret.generate()
        #expect(secret.count == 64)
        #expect(WebhookSecret.generate() != secret)
        #expect(WebhookSecret.matches(secret, secret))
        #expect(!WebhookSecret.matches(secret + "0", secret))
        #expect(!WebhookSecret.matches("", ""))
    }

    @Test("http parser waits for the body, rejects oversize, reads query and headers")
    func httpParser() {
        let head = "POST /hooks/abc?x=1 HTTP/1.1\r\nHost: l\r\nAuthorization: Bearer t\r\nContent-Length: 5\r\n\r\n"
        #expect(HTTPRequestParser.parse(Data(head.utf8)) == .incomplete)
        guard case .request(let r) = HTTPRequestParser.parse(Data((head + "hello").utf8)) else {
            Issue.record("expected a request"); return
        }
        #expect(r.method == "POST")
        #expect(r.path == "/hooks/abc")
        #expect(r.query["x"] == "1")
        #expect(r.headers["authorization"] == "Bearer t")
        #expect(String(data: r.body, encoding: .utf8) == "hello")
        let huge = "POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"
        #expect(HTTPRequestParser.parse(Data(huge.utf8)) == .tooLarge)
        #expect(HTTPRequestParser.parse(Data("garbage\r\n\r\n".utf8)) == .invalid)
    }

    @Test("an event-only routine never comes due")
    func eventOnlyCron() {
        #expect(Cron.nextDate("", from: .now) == .distantFuture)
        #expect(Cron.nextDate("   ", from: .now) == .distantFuture)
        #expect(Cron.nextDate("*/30 * * * *", from: .now) < Date.now.addingTimeInterval(31 * 60))
    }

    @Test("old routines decode with the new fields off")
    func legacyRoutine() throws {
        let json = #"{"id":"1","botId":"b","name":"n","cron":"0 9 * * *"}"#
        let r = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        #expect(!r.webhookEnabled && !r.heartbeat && !r.continuity && r.hasSchedule)
    }
}

@Suite("Webhook receiver routing")
struct WebhookRoutingTests {
    private func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> HTTPRequestParser.Request {
        .init(method: method, path: path, query: [:], headers: headers, body: Data(body.utf8))
    }

    @Test("health, auth styles, and unknown paths")
    func routing() async {
        let receiver = WebhookReceiver()
        let seen = Box()
        let handler: WebhookReceiver.Handler = { id, secret, payload in
            seen.set("\(id)|\(secret ?? "nil")|\(payload ?? "nil")")
            return .init(status: 202, message: "started")
        }
        #expect(await receiver.routeForTesting(request("GET", "/health"), handler: handler).status == 200)
        #expect(await receiver.routeForTesting(request("GET", "/nope"), handler: handler).status == 404)
        #expect(await receiver.routeForTesting(request("GET", "/hooks/r1"), handler: handler).status == 405)

        _ = await receiver.routeForTesting(request("POST", "/hooks/r1", headers: ["authorization": "Bearer abc"], body: "hi"), handler: handler)
        #expect(seen.get() == "r1|abc|hi")
        _ = await receiver.routeForTesting(request("POST", "/hooks/r1", headers: ["x-webhook-secret": "hdr"]), handler: handler)
        #expect(seen.get() == "r1|hdr|")
        _ = await receiver.routeForTesting(request("POST", "/hooks/r1/urlsecret"), handler: handler)
        #expect(seen.get() == "r1|urlsecret|")
    }
}

final class Box: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Telegram pure")
struct TelegramPureTests {
    @Test("commands parse, including the @bot suffix and unknown slashes")
    func commands() {
        #expect(TelegramCommand.parse("/start") == .start)
        #expect(TelegramCommand.parse("/Status@MyBot") == .status)
        #expect(TelegramCommand.parse("/bot  Ada ") == .use("Ada"))
        #expect(TelegramCommand.parse("/bot") == .bots)
        #expect(TelegramCommand.parse("/approve") == .approve)
        #expect(TelegramCommand.parse("/research otters") == .message("/research otters"))
        #expect(TelegramCommand.parse("hello") == .message("hello"))
    }

    @Test("long replies split under the limit without losing text")
    func chunking() {
        let text = (0..<400).map { "paragraph \($0) " + String(repeating: "w", count: 30) }.joined(separator: "\n\n")
        let chunks = TelegramFormat.chunks(text, limit: 1_000)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 1_000 })
        #expect(chunks.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        #expect(TelegramFormat.chunks("  ").isEmpty)
        #expect(TelegramFormat.chunks("short") == ["short"])
    }

    @Test("pairing codes expire, cap out, and work once")
    func pairing() {
        var pairing = TelegramPairing()
        let now = Date()
        let a = pairing.issue(chatId: 1, name: "a", now: now)
        #expect(a != nil)
        #expect(pairing.issue(chatId: 1, name: "a", now: now) == a)
        _ = pairing.issue(chatId: 2, name: "b", now: now)
        _ = pairing.issue(chatId: 3, name: "c", now: now)
        #expect(pairing.issue(chatId: 4, name: "d", now: now) == nil)
        #expect(pairing.redeem("000000x", now: now) == nil)
        #expect(pairing.redeem(a!, now: now)?.chatId == 1)
        #expect(pairing.redeem(a!, now: now) == nil)
        // An hour later the others are gone and there is room again.
        let later = now.addingTimeInterval(TelegramPairing.lifetime + 1)
        #expect(pairing.issue(chatId: 4, name: "d", now: later) != nil)
    }

    @Test("updates parse from the API shape")
    func parsing() {
        let payload: [[String: Any]] = [
            ["update_id": 7, "message": ["chat": ["id": 42, "type": "private"], "from": ["id": 42, "username": "ed", "first_name": "Ed"], "text": "hi"]],
            ["update_id": 8, "message": ["chat": ["id": -100, "type": "group"], "text": "x"]],
            ["update_id": 9, "edited_message": [:]],
        ]
        let updates = TelegramParsing.updates(from: payload)
        #expect(updates.count == 2)
        #expect(updates[0].text == "hi" && updates[0].isPrivate && updates[0].displayName == "@ed")
        #expect(!updates[1].isPrivate)
    }
}
