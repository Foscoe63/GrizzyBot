import Foundation
import Network

public struct CompanionApproval: Sendable, Equatable {
    public var botId: String
    public var botName: String
    public var tool: String
    public var detail: String
    /// False for requests that must be answered at the Mac (a secret, a computer takeover).
    public var answerableHere: Bool

    public init(botId: String, botName: String, tool: String, detail: String, answerableHere: Bool) {
        self.botId = botId
        self.botName = botName
        self.tool = tool
        self.detail = detail
        self.answerableHere = answerableHere
    }
}

/// What the phone page can do. It is the control-plane set plus answering an approval with Allow or
/// Deny — never "always allow", never a secret (typing one over plain HTTP would defeat the point).
public protocol CompanionBackend: ControlPlaneBackend {
    func pendingApprovals() async -> [CompanionApproval]
    func answerApproval(bot: String, allow: Bool) async -> String
}

/// The companion's HTTP API and page. Pure routing so it can be tested without a socket.
public struct CompanionAPI: Sendable {
    public let backend: any CompanionBackend

    public init(backend: any CompanionBackend) { self.backend = backend }

    public struct Reply: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data
        public var headers: [String: String] = [:]
    }

    private func json(_ status: Int, _ object: Any) -> Reply {
        Reply(status: status, contentType: "application/json", body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    /// `authorized` is decided by the caller from the bearer token.
    public func handle(_ request: HTTPRequestParser.Request, authorized: Bool) async -> Reply {
        if request.method == "GET", request.path == "/" || request.path == "/index.html" {
            return Reply(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(CompanionPage.html.utf8),
                headers: [
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
                    "X-Content-Type-Options": "nosniff",
                    "Referrer-Policy": "no-referrer",
                ]
            )
        }
        if request.method == "GET", request.path == "/health" { return json(200, ["ok": true]) }
        guard request.path.hasPrefix("/api/") else { return json(404, ["error": "not found"]) }
        guard authorized else { return json(401, ["error": "unauthorized"]) }

        func bodyObject() -> [String: Any] { (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:] }
        switch (request.method, request.path) {
        case ("GET", "/api/bots"):
            let pending = await backend.pendingApprovals()
            let bots = await backend.listBots().map { bot -> [String: Any] in
                ["id": bot.id, "name": bot.name, "title": bot.title, "status": bot.status,
                 "waiting": pending.contains { $0.botId == bot.id }]
            }
            return json(200, ["bots": bots])
        case ("GET", "/api/chat"):
            guard let bot = request.query["bot"], !bot.isEmpty else { return json(400, ["error": "bot is required"]) }
            let limit = min(60, max(1, Int(request.query["limit"] ?? "") ?? 30))
            guard let lines = await backend.recentMessages(bot: bot, limit: limit) else { return json(404, ["error": "no such bot"]) }
            return json(200, ["messages": lines, "status": await backend.status(bot: bot) ?? ""])
        case ("POST", "/api/send"):
            let o = bodyObject()
            guard let bot = o["bot"] as? String, let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bot.isEmpty, !text.isEmpty else { return json(400, ["error": "bot and text are required"]) }
            return json(200, ["result": await backend.send(bot: bot, text: String(text.prefix(4_000)), waitSeconds: 0)])
        case ("GET", "/api/pending"):
            let items = await backend.pendingApprovals().map { a -> [String: Any] in
                ["bot": a.botId, "botName": a.botName, "tool": a.tool, "detail": String(a.detail.prefix(1_500)), "here": a.answerableHere]
            }
            return json(200, ["pending": items])
        case ("POST", "/api/approve"):
            let o = bodyObject()
            guard let bot = o["bot"] as? String, let decision = o["decision"] as? String,
                  ["allow", "deny"].contains(decision) else { return json(400, ["error": "bot and decision (allow or deny) are required"]) }
            let pending = await backend.pendingApprovals()
            guard let item = pending.first(where: { $0.botId == bot }) else { return json(409, ["error": "nothing is waiting"]) }
            if decision == "allow", !item.answerableHere {
                return json(403, ["error": "This one has to be answered at the Mac."])
            }
            return json(200, ["result": await backend.answerApproval(bot: bot, allow: decision == "allow")])
        case ("POST", "/api/stop"):
            guard let bot = bodyObject()["bot"] as? String, !bot.isEmpty else { return json(400, ["error": "bot is required"]) }
            return json(200, ["result": await backend.interrupt(bot: bot)])
        default:
            return json(404, ["error": "not found"])
        }
    }
}

/// Serves the companion. Loopback by default; listening beyond it is an explicit setting, and every
/// API call needs the token. Repeated wrong tokens lock the API for a minute.
public actor CompanionServer {
    private var listener: NWListener?
    private var api: CompanionAPI?
    private var token = ""
    private var failures = 0
    private var lockedUntil = Date.distantPast
    public private(set) var port = 8802

    public init() {}

    public var isRunning: Bool { listener != nil }

    public func start(port: Int, allowNetwork: Bool, token: String, backend: any CompanionBackend) throws {
        stop()
        guard !token.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let parameters = NWParameters.tcp
        if !allowNetwork {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        let listener = allowNetwork ? try NWListener(using: parameters, on: nwPort) : try NWListener(using: parameters)
        self.api = CompanionAPI(backend: backend)
        self.token = token
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        api = nil
        token = ""
    }

    public func updateToken(_ token: String) { self.token = token; failures = 0 }

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                    if error != nil || (isComplete && (data ?? Data()).isEmpty) { cont.resume(returning: nil) }
                    else { cont.resume(returning: data ?? Data()) }
                }
            }
            guard let chunk else { connection.cancel(); return }
            buffer.append(chunk)
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete: continue
            case .tooLarge:
                await send(HTTPRequestParser.response(status: 413, json: ["error": "payload too large"]), on: connection)
                return
            case .invalid:
                await send(HTTPRequestParser.response(status: 400, json: ["error": "bad request"]), on: connection)
                return
            case .request(let request):
                let reply = await route(request)
                await send(HTTPRequestParser.response(status: reply.status, contentType: reply.contentType, body: reply.body, extraHeaders: reply.headers), on: connection)
                return
            }
        }
        connection.cancel()
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel(); cont.resume() })
        }
    }

    public func route(_ request: HTTPRequestParser.Request) async -> CompanionAPI.Reply {
        guard let api else { return .init(status: 503, contentType: "application/json", body: Data("{\"error\":\"stopped\"}".utf8)) }
        var authorized = false
        if request.path.hasPrefix("/api/") {
            if Date() < lockedUntil {
                return .init(status: 429, contentType: "application/json", body: Data("{\"error\":\"too many attempts — wait a minute\"}".utf8))
            }
            if let auth = request.headers["authorization"], auth.lowercased().hasPrefix("bearer "),
               WebhookSecret.matches(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces), token) {
                authorized = true
                failures = 0
            } else {
                failures += 1
                if failures >= 5 { lockedUntil = Date().addingTimeInterval(60); failures = 0 }
            }
        }
        return await api.handle(request, authorized: authorized)
    }

    public func routeForTesting(_ request: HTTPRequestParser.Request, token: String, backend: any CompanionBackend) async -> CompanionAPI.Reply {
        self.api = CompanionAPI(backend: backend)
        self.token = token
        return await route(request)
    }
}
