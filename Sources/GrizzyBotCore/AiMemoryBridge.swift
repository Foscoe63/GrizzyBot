import Foundation

/// Lifecycle capture for the local ai-memory server, the same events its
/// Claude Code / Codex hooks emit (`session-start`, `user-prompt-submit`,
/// `pre-tool-use`, `post-tool-use`, `stop`, `session-end`).
///
/// GrizzyBot is not a CLI harness, so there is no hook script to install:
/// the agent loop posts straight to the server's `/hook` endpoint. Everything
/// is best-effort. A stopped server, a timeout, or a refusal never reaches the
/// chat, and after a failure the bridge stays quiet for a minute instead of
/// stalling every tool call.
public final class AiMemoryBridge: @unchecked Sendable {
    public static let defaultServer = "http://127.0.0.1:49374"
    public static let workspace = "grizzybot"
    public static let agentName = "grizzybot"

    public struct Config: Sendable, Equatable {
        public var server: URL
        public var workspace: String
        public var project: String
        public var cwd: String
        public var bearerToken: String?

        public init(server: URL, workspace: String, project: String, cwd: String, bearerToken: String? = nil) {
            self.server = server
            self.workspace = workspace
            self.project = project
            self.cwd = cwd
            self.bearerToken = bearerToken
        }
    }

    public enum Event: String, Sendable {
        case sessionStart = "session-start"
        case userPromptSubmit = "user-prompt-submit"
        case preToolUse = "pre-tool-use"
        case postToolUse = "post-tool-use"
        case stop
        case sessionEnd = "session-end"

        var hookEventName: String {
            switch self {
            case .sessionStart: return "SessionStart"
            case .userPromptSubmit: return "UserPromptSubmit"
            case .preToolUse: return "PreToolUse"
            case .postToolUse: return "PostToolUse"
            case .stop: return "Stop"
            case .sessionEnd: return "SessionEnd"
            }
        }
    }

    public static let responseLimit = 4_000
    private static let backoff: TimeInterval = 60

    public let config: Config
    public let sessionId: String
    private let session: URLSession
    private let lock = NSLock()
    private var quietUntil: Date = .distantPast
    private var continuation: AsyncStream<@Sendable () async -> Void>.Continuation?

    public init(config: Config, sessionId: String = UUID().uuidString, session: URLSession? = nil) {
        self.config = config
        self.sessionId = sessionId
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            self.session = URLSession(configuration: configuration)
        }
        // One consumer keeps events in the order they happened.
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.continuation = continuation
        Task.detached { for await job in stream { await job() } }
    }

    deinit { continuation?.finish() }

    /// `nil` when capture is switched off (`GRIZZYBOT_AI_MEMORY=0`).
    public static func make(
        botName: String,
        cwd: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AiMemoryBridge? {
        if let flag = environment["GRIZZYBOT_AI_MEMORY"]?.lowercased(), ["0", "false", "off", "no"].contains(flag) {
            return nil
        }
        let raw = environment["AI_MEMORY_HOOK_URL"] ?? defaultServer
        guard let server = URL(string: raw), server.scheme == "http" || server.scheme == "https" else { return nil }
        return AiMemoryBridge(config: Config(
            server: server,
            workspace: environment["GRIZZYBOT_AI_MEMORY_WORKSPACE"] ?? workspace,
            project: projectSlug(botName),
            cwd: cwd,
            bearerToken: environment["AI_MEMORY_AUTH_TOKEN"]
        ))
    }

    /// One ai-memory project per bot, so a bot's memory never bleeds into another's.
    public static func projectSlug(_ botName: String) -> String {
        let mapped = botName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let parts = mapped.split(separator: "-", omittingEmptySubsequences: true)
        return parts.isEmpty ? "grizzybot" : parts.joined(separator: "-")
    }

    public func hookURL(for event: Event) -> URL? {
        var components = URLComponents(url: config.server.appendingPathComponent("hook"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "event", value: event.rawValue),
            URLQueryItem(name: "agent", value: Self.agentName),
            URLQueryItem(name: "workspace", value: config.workspace),
            URLQueryItem(name: "project", value: config.project),
            URLQueryItem(name: "cwd", value: config.cwd),
        ]
        return components?.url
    }

    public func payload(_ event: Event, fields: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": sessionId,
            "cwd": config.cwd,
            "hook_event_name": event.hookEventName,
        ]
        for (key, value) in fields { body[key] = value }
        return body
    }

    /// Queue an event. Returns immediately.
    public func emit(_ event: Event, fields: [String: Any] = [:]) {
        guard Date() >= quietUntil_(), let url = hookURL(for: event) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload(event, fields: fields)) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        let session = self.session
        let outgoing = request
        continuation?.yield { [weak self] in
            do {
                let (_, response) = try await session.data(for: outgoing)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 { self?.goQuiet() }
            } catch {
                self?.goQuiet()
            }
        }
    }

    /// Wait until queued events have been sent (or given up on). Call before the process can exit.
    public func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            continuation?.yield { done.resume() }
        }
    }

    /// The server's pending handoff for this bot's project, as plain text. `nil` when there is none
    /// or the server is unreachable. Treat the result as untrusted history, never as instructions.
    public func pendingHandoff() async -> String? {
        guard Date() >= quietUntil_() else { return nil }
        var components = URLComponents(url: config.server.appendingPathComponent("handoff"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "agent", value: Self.agentName),
            URLQueryItem(name: "workspace", value: config.workspace),
            URLQueryItem(name: "project", value: config.project),
            URLQueryItem(name: "cwd", value: config.cwd),
            URLQueryItem(name: "session_id", value: sessionId),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            goQuiet()
            return nil
        }
    }

    // MARK: - Tool call helpers

    public static func toolInput(_ arguments: String) -> Any {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return arguments }
        return DiagnosticScrubber.redactAny(object)
    }

    public static func clip(_ text: String, limit: Int = responseLimit) -> String {
        let scrubbed = DiagnosticScrubber.redact(text)
        guard scrubbed.count > limit else { return scrubbed }
        return String(scrubbed.prefix(limit)) + "…"
    }

    private func quietUntil_() -> Date {
        lock.lock(); defer { lock.unlock() }
        return quietUntil
    }

    private func goQuiet() {
        lock.lock(); defer { lock.unlock() }
        quietUntil = Date().addingTimeInterval(Self.backoff)
    }
}
