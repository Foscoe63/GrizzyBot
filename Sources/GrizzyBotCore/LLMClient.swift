import Foundation

public enum LLMError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case invalidURL(String)
    case http(Int, String)
    case emptyResponse
    case decoding(String)
    case stalled(silentForMs: Int, chunks: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No model is connected. Pick a provider in the model picker."
        case .invalidURL(let url):
            return "Model endpoint is invalid: \(url)"
        case .http(let code, let body):
            return "Model request failed (\(code)): \(body)"
        case .emptyResponse:
            return "The model returned an empty reply."
        case .decoding(let detail):
            return "Could not read the model response: \(detail)"
        case .stalled(let silentForMs, _):
            return StreamStallError(silentForMs: silentForMs, chunks: 0).errorDescription
        }
    }

    public static func transport(_ error: Error, url: URL) -> LLMError {
        .http(-1, ModelTransport.message(for: error, url: url))
    }
}

public enum ModelRequestRetry {
    public static let maxAttempts = 4

    public static func isRetryable(_ error: Error) -> Bool {
        guard let llm = error as? LLMError else { return false }
        switch llm {
        case .http(let code, let body):
            if code == 429 { return true }
            if (500...599).contains(code) { return true }
            if code == -1 { return true }
            // A context overflow succeeds on retry once the transcript is compacted.
            if isContextOverflow(code: code, body: body) { return true }
            return false
        case .stalled:
            return false
        default:
            return false
        }
    }

    public static func shouldCompactOnRetry(_ error: Error) -> Bool {
        guard let llm = error as? LLMError else { return false }
        if case .http(let code, let body) = llm {
            return (500...599).contains(code) || isContextOverflow(code: code, body: body)
        }
        return false
    }

    /// Providers report an over-long prompt as a 400/413 with wording like
    /// "maximum context length" or "prompt is too long".
    static func isContextOverflow(code: Int, body: String) -> Bool {
        guard code == 400 || code == 413 else { return false }
        let lowered = body.lowercased()
        return ["context length", "context_length", "context window", "too many tokens",
                "prompt is too long", "maximum context", "too long"].contains(where: lowered.contains)
    }

    public static func backoffNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(8.0, pow(2.0, Double(attempt)))
        return UInt64(seconds * 1_000_000_000)
    }
}

public enum ModelTransport {
    public static func isLocalNetwork(_ url: URL) -> Bool {
        let host = (url.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        return LocalProviders.isPrivateOrLoopbackIP(host)
    }

    public static func message(for error: Error, url: URL) -> String {
        let local = isLocalNetwork(url)
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                if local {
                    return "Could not reach \(url.host ?? "the local model"). Grant GrizzyBot Local Network access in System Settings → Privacy & Security → Local Network, and make sure the server is running and listening on 0.0.0.0 (not only localhost)."
                }
                return "The Mac looks offline. Check Wi-Fi or Ethernet, or connect a local provider (Ollama, LM Studio) on this machine or LAN."
            case .timedOut:
                return local
                    ? "Timed out reaching \(url.host ?? "the local model"). Check the host and that the server is running."
                    : error.localizedDescription
            case .cannotConnectToHost, .cannotFindHost:
                return local
                    ? "Nothing answered at \(url.host ?? "the local model"). Check the base URL and that the server is listening."
                    : error.localizedDescription
            default:
                break
            }
        }
        return error.localizedDescription
    }

    public static func session(for url: URL) -> URLSession {
        isLocalNetwork(url) ? localSession : cloudSession
    }

    public static func prepare(_ request: inout URLRequest) {
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.cachePolicy = .reloadIgnoringLocalCacheData
    }

    private static let cloudSession: URLSession = {
        makeSession(bypassProxy: false)
    }()

    private static let localSession: URLSession = {
        makeSession(bypassProxy: true)
    }()

    private static func makeSession(bypassProxy: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if bypassProxy {
            // System HTTP proxies make LAN/localhost look "offline" to URLSession.
            config.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0,
                "SOCKSEnable": 0,
            ]
        }
        return URLSession(configuration: config)
    }
}

public enum LLMAPIStyle: String, Sendable, Codable {
    case openAI
    case anthropic
}

public struct ModelEndpoint: Sendable, Equatable {
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var style: LLMAPIStyle
    public var extraHeaders: [String: String]

    public init(
        provider: String,
        model: String,
        baseURL: String,
        apiKey: String,
        style: LLMAPIStyle = .openAI,
        extraHeaders: [String: String] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.style = style
        self.extraHeaders = extraHeaders
    }
}

public struct ChatToolFunction: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatTool: Codable, Sendable, Equatable {
    public var type: String
    public var function: ChatToolFunction

    public init(function: ChatToolFunction) {
        self.type = "function"
        self.function = function
    }
}

public struct LLMToolCall: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public var role: String
    public var content: String?
    public var toolCallId: String?
    public var toolCalls: [LLMToolCall]
    public var name: String?
    /// JPEG base64 for vision models (computer screenshots).
    public var imageJPEGBase64: String?

    public init(
        role: String,
        content: String? = nil,
        toolCallId: String? = nil,
        toolCalls: [LLMToolCall] = [],
        name: String? = nil,
        imageJPEGBase64: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
        self.name = name
        self.imageJPEGBase64 = imageJPEGBase64
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }
    public static func tool(id: String, content: String) -> ChatMessage {
        ChatMessage(role: "tool", content: content, toolCallId: id)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
        case imageJPEGBase64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolCalls = try c.decodeIfPresent([LLMToolCall].self, forKey: .toolCalls) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        imageJPEGBase64 = try c.decodeIfPresent(String.self, forKey: .imageJPEGBase64)
    }
}

public struct ChatCompletionRequest: Sendable {
    public var endpoint: ModelEndpoint
    public var messages: [ChatMessage]
    public var tools: [ChatTool]
    public var timeout: TimeInterval
    /// Silence limit for streaming. 0 disables the watchdog.
    public var stallMs: Int

    public init(
        endpoint: ModelEndpoint,
        messages: [ChatMessage],
        tools: [ChatTool] = [],
        timeout: TimeInterval = 120,
        stallMs: Int = 60_000
    ) {
        self.endpoint = endpoint
        self.messages = messages
        self.tools = tools
        self.timeout = timeout
        self.stallMs = stallMs
    }
}

public struct ChatCompletionResponse: Sendable, Equatable {
    public var text: String
    public var toolCalls: [LLMToolCall]
    public var inputTokens: Int
    public var outputTokens: Int
    public var finishReason: String?

    public var state: JSONValue

    public init(
        text: String = "",
        toolCalls: [LLMToolCall] = [],
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        finishReason: String? = nil,
        state: JSONValue = .object([:])
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.state = state
    }

    public var hasToolCalls: Bool { !toolCalls.isEmpty }
}

public protocol ChatCompleting: Sendable {
    func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse
    func stream(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse
}

public extension ChatCompleting {
    func stream(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        let response = try await complete(request)
        if !response.text.isEmpty {
            onDelta(response.text)
        }
        return response
    }
}

/// Resolves catalog providers to OpenAI-compatible (or Anthropic) chat endpoints.
public enum LLMRouting {
    public static func endpoint(
        provider: String?,
        modelId: String?,
        apiKey: String?,
        baseUrl: String?
    ) throws -> ModelEndpoint {
        let providerId = (provider?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? ModelCatalog.defaultProvider
        let model = (modelId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? ModelCatalog.defaultModelId

        if providerId == "scripted" {
            throw LLMError.notConfigured
        }

        // Local MLX runs in-process: there is no endpoint to reach. The model
        // id carries the bundle path, and `MLXChatClient` reads it from here.
        if MLXProvider.isMLX(providerId) {
            guard !model.isEmpty else { throw LLMError.notConfigured }
            return ModelEndpoint(
                provider: providerId,
                model: model,
                baseURL: MLXProvider.inProcessBaseURL,
                apiKey: "local",
                style: .openAI
            )
        }

        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customBase = ModelCatalog.usesCustomBase(providerId)
        if trimmedKey.isEmpty && !customBase && (baseUrl == nil || baseUrl?.isEmpty == true) {
            throw LLMError.notConfigured
        }

        let style: LLMAPIStyle = providerId == "anthropic" ? .anthropic : .openAI
        let resolvedBase: String
        if let raw = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if customBase {
                resolvedBase = (try? LocalProviders.normalizeBaseUrl(raw, provider: providerId)) ?? raw
            } else {
                resolvedBase = normalizeCloudBase(raw)
            }
        } else if LocalProviders.isLocal(providerId), let def = LocalProviders.def(for: providerId) {
            resolvedBase = def.defaultBaseUrl
        } else if providerId == ModelCatalog.openaiCompatibleProvider {
            throw LLMError.notConfigured
        } else {
            resolvedBase = defaultBaseURL(for: providerId)
        }

        var headers: [String: String] = [:]
        if providerId == "openrouter" {
            headers["HTTP-Referer"] = "https://grizzybot.app"
            headers["X-Title"] = "GrizzyBot"
        }
        if providerId == "github-copilot" {
            headers["Editor-Version"] = "GrizzyBot/1.0.0"
            headers["Editor-Plugin-Version"] = "GrizzyBot/1.0.0"
            headers["Copilot-Integration-Id"] = "vscode-chat"
        }

        return ModelEndpoint(
            provider: providerId,
            model: model,
            baseURL: resolvedBase,
            apiKey: trimmedKey.isEmpty ? "local" : trimmedKey,
            style: style,
            extraHeaders: headers
        )
    }

    public static func supportsVisionImages(provider: String, model: String) -> Bool {
        let id = model.lowercased()
        if id.contains("vl") || id.contains("vision") || id.contains("llava") || id.contains("pixtral") {
            return true
        }
        if ModelCatalog.usesCustomBase(provider) {
            return id.contains("gemini")
        }
        let textOnly = [
            "gpt-3.5", "o1-mini", "o3-mini",
            "deepseek-chat", "deepseek-reasoner", "deepseek-coder",
            "codestral", "mixtral", "mistral-small",
            "llama-3", "llama3", "qwen3-coder", "qwen2.5-coder",
            "groq-llama", "compound-mini",
        ]
        if textOnly.contains(where: { id.contains($0) }) { return false }
        if id.contains("coder") && !id.contains("vision") { return false }
        return true
    }

    public static func canRun(
        provider: String?,
        apiKey: String?,
        baseUrl: String?,
        injectedClient: Bool
    ) -> Bool {
        if injectedClient { return true }
        let providerId = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if providerId == "scripted" { return false }
        if MLXProvider.isMLX(providerId) { return MLXProvider.isSupportedHardware }
        if LocalProviders.isLocal(providerId) { return true }
        if providerId == ModelCatalog.openaiCompatibleProvider {
            return !(baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return true
        }
        if let url = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return true
        }
        return false
    }

    public static func defaultBaseURL(for provider: String) -> String {
        switch provider {
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "openai", "openai-codex": return "https://api.openai.com/v1"
        case "xai": return "https://api.x.ai/v1"
        case "groq": return "https://api.groq.com/openai/v1"
        case "deepseek": return "https://api.deepseek.com/v1"
        case "mistral": return "https://api.mistral.ai/v1"
        case "google": return "https://generativelanguage.googleapis.com/v1beta/openai"
        case "anthropic": return "https://api.anthropic.com/v1"
        case "github-copilot": return "https://api.githubcopilot.com"
        case "openai-compatible": return ""
        case MLXProvider.id: return MLXProvider.inProcessBaseURL
        default:
            return LocalProviders.def(for: provider)?.defaultBaseUrl ?? "https://openrouter.ai/api/v1"
        }
    }

    private static func normalizeCloudBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmed.contains("://") {
            trimmed = "https://\(trimmed)"
        }
        if trimmed.hasSuffix("/chat/completions") {
            trimmed = String(trimmed.dropLast("/chat/completions".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return trimmed
    }
}

public struct OpenAIChatClient: ChatCompleting {
    public static let shared = OpenAIChatClient()
    private let session: URLSession?

    public init(session: URLSession? = nil) {
        self.session = session
    }

    private func session(for url: URL) -> URLSession {
        session ?? ModelTransport.session(for: url)
    }

    public func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        switch request.endpoint.style {
        case .anthropic:
            return try await completeAnthropic(request)
        case .openAI:
            return try await completeOpenAI(request)
        }
    }

    private func completeOpenAI(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let urlString = request.endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/chat/completions"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL(urlString) }

        var body: [String: Any] = [
            "model": request.endpoint.model,
            "messages": request.messages.map {
                Self.wireMessage($0, includeImages: LLMRouting.supportsVisionImages(
                    provider: request.endpoint.provider,
                    model: request.endpoint.model
                ))
            },
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.function.name,
                        "description": tool.function.description,
                        "parameters": tool.function.parameters.any,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
        }

        let data = try await postJSON(url: url, body: body, request: request, extra: request.endpoint.extraHeaders) { req in
            if request.endpoint.apiKey != "local", !request.endpoint.apiKey.isEmpty {
            req.setValue("Bearer \(request.endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        }
        return try Self.parseOpenAI(data)
    }

    public func stream(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        switch request.endpoint.style {
        case .anthropic:
            return try await streamAnthropic(request, onDelta: onDelta)
        case .openAI:
            return try await streamOpenAI(request, onDelta: onDelta)
        }
    }

    private func streamOpenAI(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        let urlString = request.endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/chat/completions"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL(urlString) }
        var body: [String: Any] = [
            "model": request.endpoint.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": request.messages.map {
                Self.wireMessage($0, includeImages: LLMRouting.supportsVisionImages(
                    provider: request.endpoint.provider,
                    model: request.endpoint.model
                ))
            },
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.function.name,
                        "description": tool.function.description,
                        "parameters": tool.function.parameters.any,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in request.endpoint.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if request.endpoint.apiKey != "local", !request.endpoint.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(request.endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        ModelTransport.prepare(&urlRequest)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session(for: url).bytes(for: urlRequest)
        } catch {
            throw LLMError.transport(error, url: url)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var snippet = ""
            for try await line in bytes.lines {
                snippet += line
                if snippet.count > 800 { break }
            }
            throw LLMError.http(status, Self.extractErrorMessage(snippet))
        }

        let monitor = StallMonitor(stallMs: request.stallMs)
        let streamTask = Task { () -> OpenAIStreamAccumulator in
            var acc = OpenAIStreamAccumulator()
            for try await line in bytes.lines {
                await monitor.touch()
                if acc.consume(line: line, onDelta: onDelta) { break }
            }
            return acc
        }
        let watchTask = Task {
            do {
                try await monitor.watchUntilStall()
            } catch is CancellationError {
                return
            } catch {
                streamTask.cancel()
            }
        }
        do {
            let acc = try await streamTask.value
            watchTask.cancel()
            return try acc.result()
        } catch is CancellationError {
            watchTask.cancel()
            let snap = await monitor.snapshot()
            if snap.stalled {
                throw LLMError.stalled(silentForMs: snap.silentForMs, chunks: snap.chunks)
            }
            throw CancellationError()
        } catch {
            watchTask.cancel()
            throw error
        }
    }

    private func streamAnthropic(
        _ request: ChatCompletionRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ChatCompletionResponse {
        let urlString = request.endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/messages"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL(urlString) }
        var body = Self.anthropicBody(request, maxTokens: Self.anthropicMaxTokens(model: request.endpoint.model, streaming: true))
        body["stream"] = true

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.endpoint.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        ModelTransport.prepare(&urlRequest)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session(for: url).bytes(for: urlRequest)
        } catch {
            throw LLMError.transport(error, url: url)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var snippet = ""
            for try await line in bytes.lines {
                snippet += line
                if snippet.count > 800 { break }
            }
            throw LLMError.http(status, Self.extractErrorMessage(snippet))
        }

        let monitor = StallMonitor(stallMs: request.stallMs)
        let streamTask = Task { () -> AnthropicStreamAccumulator in
            var acc = AnthropicStreamAccumulator()
            for try await line in bytes.lines {
                await monitor.touch()
                if try acc.consume(line: line, onDelta: onDelta) { break }
            }
            return acc
        }
        let watchTask = Task {
            do {
                try await monitor.watchUntilStall()
            } catch is CancellationError {
                return
            } catch {
                streamTask.cancel()
            }
        }
        do {
            let acc = try await streamTask.value
            watchTask.cancel()
            return try acc.result()
        } catch is CancellationError {
            watchTask.cancel()
            let snap = await monitor.snapshot()
            if snap.stalled {
                throw LLMError.stalled(silentForMs: snap.silentForMs, chunks: snap.chunks)
            }
            throw CancellationError()
        } catch {
            watchTask.cancel()
            throw error
        }
    }

    private func completeAnthropic(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let urlString = request.endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/messages"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL(urlString) }
        let body = Self.anthropicBody(request, maxTokens: Self.anthropicMaxTokens(model: request.endpoint.model, streaming: false))
        let data = try await postJSON(url: url, body: body, request: request, extra: [:]) { req in
            req.setValue(request.endpoint.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return try Self.parseAnthropic(data)
    }

    /// Output ceiling per Claude generation. A fixed 4,096 cut long artifact and
    /// write_file calls off mid-JSON. Non-streaming requests stay at 16k so a long
    /// reply cannot outlast the HTTP timeout.
    public static func anthropicMaxTokens(model: String, streaming: Bool) -> Int {
        let id = model.lowercased()
        if id.contains("claude-3-haiku") || id.contains("claude-3-opus") || id.contains("claude-3-sonnet") {
            return 4_096
        }
        if id.contains("claude-3-5") || id.contains("claude-3.5") { return 8_192 }
        return streaming ? 32_000 : 16_000
    }

    /// Messages API body: system as a cached block, tool results grouped into one user
    /// turn per assistant call (consecutive same-role messages merge), images as image
    /// blocks, and cache breakpoints on the tool list and the newest message so each
    /// agent step re-reads the long prefix from cache instead of paying for it again.
    public static func anthropicBody(_ request: ChatCompletionRequest, maxTokens: Int) -> [String: Any] {
        let cache: [String: Any] = ["type": "ephemeral"]
        let vision = LLMRouting.supportsVisionImages(provider: request.endpoint.provider, model: request.endpoint.model)
        var system = ""
        var messages: [[String: Any]] = []

        func append(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = messages.indices.last, messages[last]["role"] as? String == role,
               var existing = messages[last]["content"] as? [[String: Any]] {
                // tool_result blocks must lead a user turn.
                if role == "user", blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    let results = existing.filter { $0["type"] as? String == "tool_result" }
                    let rest = existing.filter { $0["type"] as? String != "tool_result" }
                    existing = results + blocks + rest
                } else {
                    existing += blocks
                }
                messages[last]["content"] = existing
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        for message in request.messages {
            let text = message.content ?? ""
            switch message.role {
            case "system":
                if !text.isEmpty { system += (system.isEmpty ? "" : "\n\n") + text }
            case "tool":
                append(role: "user", blocks: [[
                    "type": "tool_result",
                    "tool_use_id": message.toolCallId ?? "",
                    "content": text.isEmpty ? "(empty tool result)" : text,
                ]])
            case "assistant":
                var blocks: [[String: Any]] = []
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in message.toolCalls {
                    let parsed = JSONValue.parseObject(call.arguments)
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": parsed.isEmpty ? [String: Any]() : parsed.mapValues(\.any),
                    ])
                }
                append(role: "assistant", blocks: blocks)
            default:
                var blocks: [[String: Any]] = []
                if vision, let jpeg = message.imageJPEGBase64, !jpeg.isEmpty {
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg],
                    ])
                }
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                append(role: "user", blocks: blocks)
            }
        }

        // The Messages API requires the conversation to open on a user turn.
        if messages.first?["role"] as? String == "assistant" {
            messages.insert(["role": "user", "content": [["type": "text", "text": "(earlier conversation)"]]], at: 0)
        }

        // Rolling breakpoint on the newest block: the next step's request extends this prefix.
        if let last = messages.indices.last, var blocks = messages[last]["content"] as? [[String: Any]],
           let index = blocks.indices.last {
            blocks[index]["cache_control"] = cache
            messages[last]["content"] = blocks
        }

        var body: [String: Any] = [
            "model": request.endpoint.model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": cache]]
        }
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = request.tools.map { tool in
                [
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "input_schema": tool.function.parameters.any,
                ]
            }
            tools[tools.count - 1]["cache_control"] = cache
            body["tools"] = tools
        }
        return body
    }

    private func postJSON(
        url: URL,
        body: [String: Any],
        request: ChatCompletionRequest,
        extra: [String: String],
        authorize: (inout URLRequest) -> Void
    ) async throws -> Data {
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in extra {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        authorize(&urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        ModelTransport.prepare(&urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session(for: url).data(for: urlRequest)
        } catch {
            throw LLMError.transport(error, url: url)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(status, Self.extractErrorMessage(snippet))
        }
        return data
    }

    public static func parseOpenAI(_ data: Data) throws -> ChatCompletionResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("not an object")
        }
        let usage = root["usage"] as? [String: Any]
        let input = intValue(usage?["prompt_tokens"] ?? usage?["input_tokens"])
        let output = intValue(usage?["completion_tokens"] ?? usage?["output_tokens"])
        let choices = root["choices"] as? [[String: Any]] ?? []
        guard let first = choices.first else { throw LLMError.emptyResponse }
        let message = first["message"] as? [String: Any] ?? [:]
        let text = extractText(message["content"])
        let finish = first["finish_reason"] as? String
        var calls: [LLMToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for item in rawCalls {
                let id = (item["id"] as? String) ?? UUID().uuidString
                let fn = item["function"] as? [String: Any] ?? [:]
                let name = (fn["name"] as? String) ?? ""
                let args: String
                if let string = fn["arguments"] as? String {
                    args = string
                } else if let object = fn["arguments"] {
                    args = stringifyJSON(object)
                } else {
                    args = "{}"
                }
                if !name.isEmpty {
                    calls.append(LLMToolCall(id: id, name: name, arguments: args))
                }
            }
        }
        if text.isEmpty && calls.isEmpty { throw LLMError.emptyResponse }
        return ChatCompletionResponse(
            text: text,
            toolCalls: calls,
            inputTokens: input,
            outputTokens: output,
            finishReason: finish
        )
    }

    public static func parseOpenAIStream(
        _ data: Data,
        onDelta: @escaping @Sendable (String) -> Void
    ) throws -> ChatCompletionResponse {
        var acc = OpenAIStreamAccumulator()
        let raw = String(data: data, encoding: .utf8) ?? ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if acc.consume(line: String(line), onDelta: onDelta) { break }
        }
        do {
            return try acc.result()
        } catch {
            if let fallback = try? parseOpenAI(data) { return fallback }
            throw error
        }
    }

    public static func parseAnthropic(_ data: Data) throws -> ChatCompletionResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("not an object")
        }
        let usage = root["usage"] as? [String: Any]
        // Cached prefix tokens are reported separately; they still fill the window.
        let input = intValue(usage?["input_tokens"])
            + intValue(usage?["cache_creation_input_tokens"])
            + intValue(usage?["cache_read_input_tokens"])
        let output = intValue(usage?["output_tokens"])
        let blocks = root["content"] as? [[String: Any]] ?? []
        var text = ""
        var calls: [LLMToolCall] = []
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if type == "text", let piece = block["text"] as? String {
                text += piece
            } else if type == "tool_use" {
                let id = (block["id"] as? String) ?? UUID().uuidString
                let name = (block["name"] as? String) ?? ""
                let inputObj = block["input"] ?? [String: Any]()
                if !name.isEmpty {
                    calls.append(LLMToolCall(id: id, name: name, arguments: stringifyJSON(inputObj)))
                }
            }
        }
        if text.isEmpty && calls.isEmpty { throw LLMError.emptyResponse }
        return ChatCompletionResponse(
            text: text,
            toolCalls: calls,
            inputTokens: input,
            outputTokens: output,
            finishReason: root["stop_reason"] as? String
        )
    }

    public static func wireMessage(_ message: ChatMessage, includeImages: Bool = true) -> [String: Any] {
        var body: [String: Any] = ["role": message.role]
        if let name = message.name { body["name"] = name }
        if let toolCallId = message.toolCallId { body["tool_call_id"] = toolCallId }
        if !message.toolCalls.isEmpty {
            body["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": ContextCompactor.ensureValidJSONArguments(call.arguments),
                    ],
                ]
            }
            body["content"] = message.content ?? ""
        } else if includeImages,
                  message.role != "tool",
                  let jpeg = message.imageJPEGBase64, !jpeg.isEmpty {
            var parts: [[String: Any]] = []
            if let content = message.content, !content.isEmpty {
                parts.append(["type": "text", "text": content])
            }
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg)"],
            ])
            body["content"] = parts
        } else {
            body["content"] = message.content ?? ""
        }
        return body
    }

    private static func extractText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func stringifyJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private static func extractErrorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "empty error body" : String(trimmed.prefix(400))
    }

    static func streamText(_ value: Any?) -> String { extractText(value) }
    static func streamInt(_ value: Any?) -> Int { intValue(value) }
}

/// Messages API server-sent events: text deltas stream to the UI, tool_use input
/// arrives as partial JSON per content block, usage splits across start and delta.
public struct AnthropicStreamAccumulator: Sendable {
    public init() {}

    var text = ""
    var inputTokens = 0
    var outputTokens = 0
    var stopReason: String?
    var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    /// Returns true on `message_stop`. Throws on an in-stream `error` event.
    public mutating func consume(line: String, onDelta: @escaping @Sendable (String) -> Void) throws -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let index = OpenAIChatClient.streamInt(json["index"])
        switch json["type"] as? String {
        case "message_start":
            let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
            inputTokens = OpenAIChatClient.streamInt(usage["input_tokens"])
                + OpenAIChatClient.streamInt(usage["cache_creation_input_tokens"])
                + OpenAIChatClient.streamInt(usage["cache_read_input_tokens"])
        case "content_block_start":
            if let block = json["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                calls[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
            }
        case "content_block_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                let piece = delta["text"] as? String ?? ""
                if !piece.isEmpty {
                    text += piece
                    onDelta(piece)
                }
            case "input_json_delta":
                calls[index]?.arguments += delta["partial_json"] as? String ?? ""
            default:
                break
            }
        case "message_delta":
            if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String {
                stopReason = reason
            }
            if let usage = json["usage"] as? [String: Any] {
                outputTokens = OpenAIChatClient.streamInt(usage["output_tokens"])
            }
        case "message_stop":
            return true
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            let kind = error["type"] as? String ?? "error"
            let code = kind == "overloaded_error" ? 529 : 500
            throw LLMError.http(code, error["message"] as? String ?? kind)
        default:
            break
        }
        return false
    }

    public func result() throws -> ChatCompletionResponse {
        let toolCalls = calls.keys.sorted().compactMap { index -> LLMToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return LLMToolCall(
                id: call.id.isEmpty ? UUID().uuidString : call.id,
                name: call.name,
                arguments: call.arguments.isEmpty ? "{}" : call.arguments
            )
        }
        if text.isEmpty && toolCalls.isEmpty { throw LLMError.emptyResponse }
        return ChatCompletionResponse(
            text: text,
            toolCalls: toolCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            finishReason: stopReason
        )
    }
}

private struct OpenAIStreamAccumulator {
    var text = ""
    var inputTokens = 0
    var outputTokens = 0
    var finishReason: String?
    var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    /// Returns true when the stream is finished (`data: [DONE]`).
    mutating func consume(line: String, onDelta: @escaping @Sendable (String) -> Void) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        guard let chunkData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
            return false
        }
        if let usage = json["usage"] as? [String: Any] {
            inputTokens = OpenAIChatClient.streamInt(usage["prompt_tokens"] ?? usage["input_tokens"])
            outputTokens = OpenAIChatClient.streamInt(usage["completion_tokens"] ?? usage["output_tokens"])
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        guard let first = choices.first else { return false }
        if let reason = first["finish_reason"] as? String { finishReason = reason }
        let delta = (first["delta"] as? [String: Any]) ?? [:]
        let piece = OpenAIChatClient.streamText(delta["content"])
        if !piece.isEmpty {
            text += piece
            onDelta(piece)
        }
        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
            for item in rawCalls {
                let index = OpenAIChatClient.streamInt(item["index"])
                var current = calls[index] ?? (id: "", name: "", arguments: "")
                if let id = item["id"] as? String, !id.isEmpty { current.id = id }
                let fn = item["function"] as? [String: Any] ?? [:]
                if let name = fn["name"] as? String, !name.isEmpty { current.name += name }
                if let args = fn["arguments"] as? String { current.arguments += args }
                calls[index] = current
            }
        }
        return false
    }

    func result() throws -> ChatCompletionResponse {
        let toolCalls = calls.keys.sorted().compactMap { index -> LLMToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return LLMToolCall(
                id: call.id.isEmpty ? UUID().uuidString : call.id,
                name: call.name,
                arguments: call.arguments.isEmpty ? "{}" : call.arguments
            )
        }
        if text.isEmpty && toolCalls.isEmpty { throw LLMError.emptyResponse }
        return ChatCompletionResponse(
            text: text,
            toolCalls: toolCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            finishReason: finishReason
        )
    }
}
