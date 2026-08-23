import Foundation
import Network

/// Local OpenAI-compatible + thin MCP HTTP gateway so Cursor/other clients can call GrizzyBot bots.
public actor LocalOpenAIGateway {
    public static let shared = LocalOpenAIGateway()

    public struct Settings: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var port: Int
        public var apiKey: String
        public var defaultBotId: String?

        public static let `default` = Settings(enabled: false, port: 8787, apiKey: "", defaultBotId: nil)

        public init(enabled: Bool = false, port: Int = 8787, apiKey: String = "", defaultBotId: String? = nil) {
            self.enabled = enabled
            self.port = port
            self.apiKey = apiKey
            self.defaultBotId = defaultBotId
        }
    }

    public typealias ChatHandler = @Sendable (_ botId: String?, _ messages: [[String: String]], _ model: String?) async throws -> String

    private var listener: NWListener?
    private var settings: Settings = .default
    private var handler: ChatHandler?
    private var bots: [(id: String, name: String)] = []

    public func configure(
        settings: Settings,
        bots: [(id: String, name: String)],
        handler: @escaping ChatHandler
    ) {
        self.settings = settings
        self.bots = bots
        self.handler = handler
    }

    public func restart() async {
        stop()
        guard settings.enabled else { return }
        try? startListening()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public var isRunning: Bool { listener != nil }

    private func startListening() throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.port)) else { return }
        let listener = try NWListener(using: .tcp, on: port)
        let settings = self.settings
        let bots = self.bots
        let handler = self.handler
        listener.newConnectionHandler = { connection in
            Task {
                await LocalOpenAIGateway.shared.serve(
                    connection: connection,
                    settings: settings,
                    bots: bots,
                    handler: handler
                )
            }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private func serve(
        connection: NWConnection,
        settings: Settings,
        bots: [(id: String, name: String)],
        handler: ChatHandler?
    ) async {
        connection.start(queue: .global(qos: .utility))
        var buffer = Data()
        while true {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                    if isComplete, data == nil || data?.isEmpty == true {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: data ?? Data())
                    }
                }
            }
            guard let chunk else {
                connection.cancel()
                return
            }
            buffer.append(chunk)
            guard let response = await handleHTTP(buffer, settings: settings, bots: bots, handler: handler) else {
                continue
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                    cont.resume()
                })
            }
            return
        }
    }

    private func handleHTTP(
        _ data: Data,
        settings: Settings,
        bots: [(id: String, name: String)],
        handler: ChatHandler?
    ) async -> Data? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n")
        else { return nil }
        let header = String(raw[..<headerEnd.lowerBound])
        let body = String(raw[headerEnd.upperBound...])
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        let contentLength = lines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        if contentLength > 0, body.utf8.count < contentLength {
            return nil
        }

        let auth = lines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        if !settings.apiKey.isEmpty {
            let expected = "Bearer \(settings.apiKey)"
            guard auth.contains(expected) else {
                return Self.httpJSON(status: 401, object: ["error": ["message": "Unauthorized", "type": "auth"]])
            }
        }

        if method == "GET", path == "/v1/models" || path.hasPrefix("/v1/models?") {
            let data: [[String: Any]] = bots.map { bot in
                [
                    "id": "grizzybot/\(bot.id)",
                    "object": "model",
                    "owned_by": "grizzybot",
                    "name": bot.name,
                ]
            }
            return Self.httpJSON(status: 200, object: ["object": "list", "data": data])
        }

        if method == "GET", path == "/health" {
            return Self.httpJSON(status: 200, object: ["ok": true, "service": "grizzybot-local"])
        }

        if method == "GET", path == "/mcp/tools" {
            return Self.httpJSON(status: 200, object: [
                "tools": [[
                    "name": "grizzybot_run",
                    "description": "Run a GrizzyBot bot with a user prompt under local governance.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "bot_id": ["type": "string"],
                            "prompt": ["type": "string"],
                        ],
                        "required": ["prompt"],
                    ],
                ]],
            ])
        }

        if method == "POST", path == "/v1/chat/completions" || path == "/mcp/call" {
            guard let handler else {
                return Self.httpJSON(status: 503, object: ["error": ["message": "Handler not ready"]])
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                return Self.httpJSON(status: 400, object: ["error": ["message": "Invalid JSON"]])
            }
            do {
                let reply: String
                if path == "/mcp/call" {
                    let name = (json["name"] as? String) ?? "grizzybot_run"
                    let args = (json["arguments"] as? [String: Any]) ?? [:]
                    let prompt = (args["prompt"] as? String) ?? ""
                    let botId = (args["bot_id"] as? String) ?? settings.defaultBotId
                    guard name == "grizzybot_run", !prompt.isEmpty else {
                        return Self.httpJSON(status: 400, object: ["error": ["message": "Expected grizzybot_run with prompt"]])
                    }
                    reply = try await handler(botId, [["role": "user", "content": prompt]], nil)
                    return Self.httpJSON(status: 200, object: ["content": [["type": "text", "text": reply]]])
                } else {
                    let model = json["model"] as? String
                    let botId = Self.botId(fromModel: model, defaultBotId: settings.defaultBotId)
                    let messages = ((json["messages"] as? [[String: Any]]) ?? []).compactMap { row -> [String: String]? in
                        guard let role = row["role"] as? String,
                              let content = row["content"] as? String
                        else { return nil }
                        return ["role": role, "content": content]
                    }
                    reply = try await handler(botId, messages, model)
                    let id = "chatcmpl-\(UUID().uuidString.prefix(8))"
                    return Self.httpJSON(status: 200, object: [
                        "id": id,
                        "object": "chat.completion",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": "grizzybot",
                        "choices": [[
                            "index": 0,
                            "message": ["role": "assistant", "content": reply],
                            "finish_reason": "stop",
                        ]],
                    ])
                }
            } catch {
                return Self.httpJSON(status: 500, object: ["error": ["message": error.localizedDescription]])
            }
        }

        return Self.httpJSON(status: 404, object: ["error": ["message": "Not found"]])
    }

    private static func botId(fromModel model: String?, defaultBotId: String?) -> String? {
        guard let model, !model.isEmpty else { return defaultBotId }
        if model.hasPrefix("grizzybot/") {
            return String(model.dropFirst("grizzybot/".count))
        }
        return defaultBotId ?? model
    }

    private static func httpJSON(status: Int, object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let header =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
