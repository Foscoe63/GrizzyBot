import Foundation
import Network

/// What an outside MCP client (Claude Desktop, Cursor, Claude Code) is allowed to do with your bots.
///
/// The boundary is deliberate: list, read, search, send a message, wait for the answer, stop a run,
/// and switch a model. There is nothing for approvals, deleting anything, credentials, settings, or
/// the computer — those stay in the app, with you.
public protocol ControlPlaneBackend: Sendable {
    func listBots() async -> [ControlPlaneBot]
    func status(bot: String) async -> String?
    func recentMessages(bot: String, limit: Int) async -> [String]?
    func search(query: String, bot: String?) async -> [String]
    func send(bot: String, text: String, waitSeconds: Int) async -> String
    func interrupt(bot: String) async -> String
    func setModel(bot: String, provider: String, model: String) async -> String
}

public struct ControlPlaneBot: Sendable, Equatable {
    public var id: String
    public var name: String
    public var title: String
    public var status: String

    public init(id: String, name: String, title: String, status: String) {
        self.id = id
        self.name = name
        self.title = title
        self.status = status
    }
}

/// A minimal MCP server (JSON-RPC 2.0 over HTTP) with the tools above.
public struct ControlPlaneMCP: Sendable {
    public static let protocolVersion = "2025-03-26"
    public let backend: any ControlPlaneBackend

    public init(backend: any ControlPlaneBackend) {
        self.backend = backend
    }

    public static let toolNames = [
        "grizzybot_list_bots", "grizzybot_bot_status", "grizzybot_read_chat",
        "grizzybot_search_chats", "grizzybot_send_message", "grizzybot_interrupt", "grizzybot_set_model",
    ]

    private static func schema(_ properties: [String: (String, Bool)]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for (key, value) in properties {
            props[key] = ["type": "string", "description": value.0]
            if value.1 { required.append(key) }
        }
        return ["type": "object", "properties": props, "required": required.sorted()]
    }

    static var toolList: [[String: Any]] {
        [
            ["name": "grizzybot_list_bots", "description": "List the bots on this Mac with their roles and whether they are busy.", "inputSchema": schema([:])],
            ["name": "grizzybot_bot_status", "description": "What one bot is doing right now.", "inputSchema": schema(["bot": ("Bot name or id", true)])],
            ["name": "grizzybot_read_chat", "description": "The most recent messages in a bot's main chat.", "inputSchema": schema(["bot": ("Bot name or id", true), "limit": ("How many messages (default 10, max 40)", false)])],
            ["name": "grizzybot_search_chats", "description": "Search a bot's earlier chats for a phrase.", "inputSchema": schema(["query": ("Keywords", true), "bot": ("Bot name or id; omit to search every bot", false)])],
            ["name": "grizzybot_send_message", "description": "Send a message to a bot as if you typed it, optionally waiting for its reply. If the bot needs an approval it will say so; approvals are answered in GrizzyBot, not here.", "inputSchema": schema(["bot": ("Bot name or id", true), "text": ("The message", true), "wait_seconds": ("Seconds to wait for the reply (0 = don't wait, max 120)", false)])],
            ["name": "grizzybot_interrupt", "description": "Stop a bot's current run.", "inputSchema": schema(["bot": ("Bot name or id", true)])],
            ["name": "grizzybot_set_model", "description": "Switch which model a bot uses.", "inputSchema": schema(["bot": ("Bot name or id", true), "provider": ("Provider id, e.g. anthropic, openrouter, ollama", true), "model": ("Model id", true)])],
        ]
    }

    /// Handles one JSON-RPC message. Returns nil for notifications (no reply is sent).
    public func handle(_ body: Data) async -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.error(id: nil, code: -32700, message: "Parse error")
        }
        let id = object["id"]
        guard let method = object["method"] as? String else {
            return Self.error(id: id, code: -32600, message: "Invalid request")
        }
        if id == nil { return nil } // notification, e.g. notifications/initialized
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "grizzybot", "version": "1"],
                "instructions": "Control your GrizzyBot team: list bots, read and search chats, send a message and wait for the reply. Approvals, deletion, credentials and settings are not available here.",
            ])
        case "ping":
            return Self.result(id: id, [String: Any]())
        case "tools/list":
            return Self.result(id: id, ["tools": Self.toolList])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await call(tool: name, args: args)
            return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(tool: String, args: [String: Any]) async -> (String, Bool) {
        func str(_ key: String) -> String { (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func int(_ key: String) -> Int? {
            if let n = args[key] as? Int { return n }
            if let s = args[key] as? String { return Int(s) }
            return nil
        }
        switch tool {
        case "grizzybot_list_bots":
            let bots = await backend.listBots()
            if bots.isEmpty { return ("No bots yet.", false) }
            return (bots.map { "\($0.name)\($0.title.isEmpty ? "" : " — \($0.title)") [\($0.status)] (id \($0.id))" }.joined(separator: "\n"), false)
        case "grizzybot_bot_status":
            guard !str("bot").isEmpty else { return ("bot is required", true) }
            guard let text = await backend.status(bot: str("bot")) else { return ("No bot matches “\(str("bot"))”.", true) }
            return (text, false)
        case "grizzybot_read_chat":
            guard !str("bot").isEmpty else { return ("bot is required", true) }
            let limit = min(40, max(1, int("limit") ?? 10))
            guard let lines = await backend.recentMessages(bot: str("bot"), limit: limit) else { return ("No bot matches “\(str("bot"))”.", true) }
            return (lines.isEmpty ? "No messages yet." : lines.joined(separator: "\n\n"), false)
        case "grizzybot_search_chats":
            guard !str("query").isEmpty else { return ("query is required", true) }
            let hits = await backend.search(query: str("query"), bot: str("bot").isEmpty ? nil : str("bot"))
            return (hits.isEmpty ? "Nothing matches." : hits.joined(separator: "\n\n"), false)
        case "grizzybot_send_message":
            guard !str("bot").isEmpty, !str("text").isEmpty else { return ("bot and text are required", true) }
            let wait = min(120, max(0, int("wait_seconds") ?? 0))
            return (await backend.send(bot: str("bot"), text: str("text"), waitSeconds: wait), false)
        case "grizzybot_interrupt":
            guard !str("bot").isEmpty else { return ("bot is required", true) }
            return (await backend.interrupt(bot: str("bot")), false)
        case "grizzybot_set_model":
            guard !str("bot").isEmpty, !str("provider").isEmpty, !str("model").isEmpty else { return ("bot, provider and model are required", true) }
            return (await backend.setModel(bot: str("bot"), provider: str("provider"), model: str("model")), false)
        default:
            return ("Unknown tool \(tool). This server only offers: \(Self.toolNames.joined(separator: ", ")).", true)
        }
    }

    static func result(id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

/// Loopback-only HTTP listener for the control plane: `GET /health` and `POST /mcp`, bearer token required.
public actor ControlPlaneServer {
    public static let defaultPort = 8801

    private var listener: NWListener?
    private var mcp: ControlPlaneMCP?
    private var token: String = ""
    public private(set) var port: Int = ControlPlaneServer.defaultPort

    public init() {}

    public var isRunning: Bool { listener != nil }

    public func start(port: Int, token: String, backend: any ControlPlaneBackend) throws {
        stop()
        guard !token.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        self.mcp = ControlPlaneMCP(backend: backend)
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
        mcp = nil
        token = ""
    }

    public func updateToken(_ token: String) { self.token = token }

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                    if error != nil || (isComplete && (data ?? Data()).isEmpty) {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: data ?? Data())
                    }
                }
            }
            guard let chunk else { connection.cancel(); return }
            buffer.append(chunk)
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                continue
            case .tooLarge:
                await send(HTTPRequestParser.response(status: 413, json: ["error": "payload too large"]), on: connection)
                return
            case .invalid:
                await send(HTTPRequestParser.response(status: 400, json: ["error": "bad request"]), on: connection)
                return
            case .request(let request):
                let (status, body) = await route(request)
                let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                await send(HTTPRequestParser.response(status: status, json: json), on: connection)
                return
            }
        }
        connection.cancel()
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
                cont.resume()
            })
        }
    }

    /// Exposed for tests so auth and routing are checked without opening a socket.
    public func route(_ request: HTTPRequestParser.Request) async -> (Int, Data) {
        let (status, json) = await routeJSON(request)
        return (status, (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
    }

    private func routeJSON(_ request: HTTPRequestParser.Request) async -> (Int, [String: Any]) {
        if request.method == "GET", request.path == "/health" { return (200, ["ok": true]) }
        guard request.path == "/mcp" else { return (404, ["error": "not found"]) }
        guard request.method == "POST" else { return (405, ["error": "use POST"]) }
        guard let auth = request.headers["authorization"], auth.lowercased().hasPrefix("bearer "),
              WebhookSecret.matches(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces), token)
        else { return (401, ["error": "unauthorized"]) }
        guard let mcp else { return (503, ["error": "stopped"]) }
        guard let reply = await mcp.handle(request.body) else { return (202, [:]) }
        return (200, reply)
    }

    public func routeForTesting(_ request: HTTPRequestParser.Request, token: String, backend: any ControlPlaneBackend) async -> (Int, Data) {
        self.mcp = ControlPlaneMCP(backend: backend)
        self.token = token
        return await route(request)
    }
}
