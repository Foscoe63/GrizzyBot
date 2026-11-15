import Foundation

/// Spike: GrizzyBot as an Agent Client Protocol client. It launches an external coding agent
/// (`opencode acp`, or any ACP agent) as a subprocess and drives it over newline-delimited JSON-RPC
/// on stdio. Not wired into the app yet.
public enum AcpError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case transport(String)
    case remote(code: Int, message: String)
    case notStarted
    case closed

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let s): return "Could not start the agent: \(s)"
        case .transport(let s): return s
        case .remote(let code, let message): return "Agent error \(code): \(message)"
        case .notStarted: return "The agent session has not been started."
        case .closed: return "The agent exited."
        }
    }
}

/// What the agent streams back while it works on a prompt.
public enum AcpUpdate: Sendable, Equatable {
    case text(String)
    case thought(String)
    case toolStarted(id: String, title: String, kind: String)
    case toolUpdated(id: String, status: String, title: String)
    case plan([String])
    case other(String)
}

/// The agent asking before it does something.
public struct AcpPermissionRequest: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var id: String
        public var name: String
        /// allow_once, allow_always, reject_once or reject_always.
        public var kind: String

        public init(id: String, name: String, kind: String) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }
    public var toolTitle: String
    public var toolKind: String
    public var options: [Option]

    public init(toolTitle: String, toolKind: String, options: [Option]) {
        self.toolTitle = toolTitle
        self.toolKind = toolKind
        self.options = options
    }
}

public struct AcpPromptResult: Sendable, Equatable {
    public var text: String
    public var stopReason: String
}

public actor AcpClient {
    public static let protocolVersion = 1

    private let process = Process()
    private let stdin: FileHandle
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessionId: String?
    private var closed = false
    private var onUpdate: (@Sendable (AcpUpdate) -> Void)?
    private var onPermission: (@Sendable (AcpPermissionRequest) async -> String?)?
    private var collected = ""
    private var stderrTail = Data()
    public private(set) var agentName = ""

    /// `command` is the executable followed by its arguments, for example `["opencode", "acp"]`.
    public init(command: [String], cwd: String, environment: [String: String] = [:]) throws {
        guard let first = command.first, !first.isEmpty else {
            throw AcpError.launchFailed("no command")
        }
        process.executableURL = URL(fileURLWithPath: first.hasPrefix("/") ? first : "/usr/bin/env")
        process.arguments = first.hasPrefix("/") ? Array(command.dropFirst()) : command
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.opencode/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        stdin = inPipe.fileHandleForWriting
        do { try process.run() } catch { throw AcpError.launchFailed(error.localizedDescription) }

        let lines = AcpLineStream(outPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in lines.stream { await self?.handle(line: line) }
            await self?.finish()
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { await self?.noteStderr(data) }
        }
    }

    // MARK: Session

    /// Handshake and a new session in `cwd`. Returns the agent's session id.
    @discardableResult
    public func start(cwd: String) async throws -> String {
        let initResult = try await request("initialize", [
            "protocolVersion": Self.protocolVersion,
            // Honest about what this client can do: it answers permission requests and nothing else yet.
            "clientCapabilities": [String: Any](),
            "clientInfo": ["name": "GrizzyBot", "version": "0.1"],
        ])
        if let info = initResult["agentInfo"] as? [String: Any], let name = info["name"] as? String {
            agentName = name
        }
        let created = try await request("session/new", ["cwd": cwd, "mcpServers": [Any]()])
        guard let id = created["sessionId"] as? String else {
            throw AcpError.transport("session/new returned no sessionId")
        }
        sessionId = id
        return id
    }

    /// Sends one prompt and waits for the agent to finish it. Updates stream through `onUpdate`; a
    /// permission request is answered with the option id `onPermission` returns, or cancelled when it
    /// returns nil.
    public func prompt(
        _ text: String,
        onUpdate: (@Sendable (AcpUpdate) -> Void)? = nil,
        onPermission: (@Sendable (AcpPermissionRequest) async -> String?)? = nil
    ) async throws -> AcpPromptResult {
        guard let sessionId else { throw AcpError.notStarted }
        self.onUpdate = onUpdate
        self.onPermission = onPermission
        collected = ""
        defer { self.onUpdate = nil; self.onPermission = nil }
        let result = try await request("session/prompt", [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ])
        return AcpPromptResult(text: collected, stopReason: (result["stopReason"] as? String) ?? "")
    }

    /// Sets a session option the agent advertised in `session/new`, such as `model`.
    public func setConfigOption(_ id: String, value: String) async throws {
        guard let sessionId else { throw AcpError.notStarted }
        _ = try await request("session/set_config_option", [
            "sessionId": sessionId, "configId": id, "value": value,
        ])
    }

    /// Asks the agent to stop the current prompt. It still answers the prompt, with stopReason "cancelled".
    public func cancel() {
        guard let sessionId else { return }
        send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
    }

    public func close() {
        guard !closed else { return }
        closed = true
        try? stdin.close()
        if process.isRunning { process.terminate() }
        failAll(AcpError.closed)
    }

    // MARK: Wire

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard !closed else { throw AcpError.closed }
        let id = nextId
        nextId += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func send(_ message: [String: Any]) {
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func handle(line: Data) async {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let method = object["method"] as? String
        let id = object["id"]
        if let method {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id {
                await handleAgentRequest(id: id, method: method, params: params)
            } else if method == "session/update" {
                handleUpdate(params["update"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let responseId = id as? Int, let continuation = pending.removeValue(forKey: responseId) else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: AcpError.remote(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "unknown"
            ))
        } else {
            continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
        }
    }

    private func handleAgentRequest(id: Any, method: String, params: [String: Any]) async {
        switch method {
        case "session/request_permission":
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let options = (params["options"] as? [[String: Any]] ?? []).map {
                AcpPermissionRequest.Option(
                    id: $0["optionId"] as? String ?? "",
                    name: $0["name"] as? String ?? "",
                    kind: $0["kind"] as? String ?? ""
                )
            }
            let ask = AcpPermissionRequest(
                toolTitle: call["title"] as? String ?? "",
                toolKind: call["kind"] as? String ?? "",
                options: options
            )
            // Nobody to ask means no: an unattended coding agent never gets a yes by default.
            let chosen = await onPermission?(ask)
            let outcome: [String: Any] = chosen.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
            send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported: \(method)"]])
        }
    }

    private func handleUpdate(_ update: [String: Any]) {
        let kind = update["sessionUpdate"] as? String ?? ""
        let content = update["content"] as? [String: Any]
        let text = content?["text"] as? String ?? ""
        switch kind {
        case "agent_message_chunk":
            collected += text
            onUpdate?(.text(text))
        case "agent_thought_chunk":
            onUpdate?(.thought(text))
        case "tool_call":
            onUpdate?(.toolStarted(
                id: update["toolCallId"] as? String ?? "",
                title: update["title"] as? String ?? "",
                kind: update["kind"] as? String ?? ""
            ))
        case "tool_call_update":
            onUpdate?(.toolUpdated(
                id: update["toolCallId"] as? String ?? "",
                status: update["status"] as? String ?? "",
                title: update["title"] as? String ?? ""
            ))
        case "plan":
            let entries = (update["entries"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
            onUpdate?(.plan(entries))
        default:
            onUpdate?(.other(kind))
        }
    }

    private func noteStderr(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > 4000 { stderrTail = stderrTail.suffix(4000) }
    }

    private func finish() {
        let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        failAll(tail.isEmpty ? AcpError.closed : AcpError.transport("The agent exited. \(tail)"))
        closed = true
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending = [:]
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}

/// Splits a pipe into lines as they arrive.
private final class AcpLineStream: @unchecked Sendable {
    let stream: AsyncStream<Data>

    init(_ handle: FileHandle) {
        var continuation: AsyncStream<Data>.Continuation!
        stream = AsyncStream { continuation = $0 }
        let cont = continuation!
        let splitter = Splitter()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                cont.finish()
                return
            }
            for line in splitter.feed(data) { cont.yield(line) }
        }
    }

    private final class Splitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func feed(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}
