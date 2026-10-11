import Foundation
import Network

/// Loopback-only HTTP receiver that lets an outside system fire a routine.
///
/// It exposes exactly two things — `GET /health` and `POST /hooks/<routineId>` — and nothing of
/// the app's wider surface. Each routine has its own secret, shown once and kept in the Keychain.
/// To reach it from the internet, proxy only this port (a tunnel such as Tailscale Funnel).
public actor WebhookReceiver {
    public struct Outcome: Sendable, Equatable {
        public var status: Int
        public var message: String
        public init(status: Int, message: String) {
            self.status = status
            self.message = message
        }
    }

    /// (routineId, suppliedSecret, payload) → outcome. Runs on the main actor in the app.
    public typealias Handler = @Sendable (_ routineId: String, _ secret: String?, _ payload: String?) async -> Outcome

    public static let defaultPort = 8800

    private var listener: NWListener?
    private var handler: Handler?
    public private(set) var port: Int = WebhookReceiver.defaultPort

    public init() {}

    public var isRunning: Bool { listener != nil }

    public func start(port: Int, handler: @escaping Handler) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let parameters = NWParameters.tcp
        // Loopback only: the receiver must never be reachable from the local network by default.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        self.handler = handler
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
        handler = nil
    }

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
                let outcome = await route(request)
                await send(
                    HTTPRequestParser.response(status: outcome.status, json: ["ok": outcome.status < 300, "message": outcome.message]),
                    on: connection
                )
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

    /// Exposed for tests so routing and auth are checked without opening a socket.
    public func route(_ request: HTTPRequestParser.Request) async -> Outcome {
        if request.method == "GET", request.path == "/health" {
            return Outcome(status: 200, message: "ok")
        }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "hooks" else {
            return Outcome(status: 404, message: "not found")
        }
        guard request.method == "POST" else {
            return Outcome(status: 405, message: "use POST")
        }
        let routineId = parts[1]
        // Bearer header is preferred so the secret stays out of URLs and access logs; the
        // capability URL (/hooks/<id>/<secret>) exists for senders that cannot set headers.
        var secret: String?
        if let auth = request.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            secret = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let header = request.headers["x-webhook-secret"] {
            secret = header
        } else if parts.count >= 3 {
            secret = parts[2]
        }
        let payload = String(data: request.body, encoding: .utf8)
        guard let handler else { return Outcome(status: 404, message: "not found") }
        return await handler(routineId, secret, payload)
    }

    public func routeForTesting(_ request: HTTPRequestParser.Request, handler: @escaping Handler) async -> Outcome {
        self.handler = handler
        return await route(request)
    }
}
