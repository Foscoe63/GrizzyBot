import Foundation

public enum AgentPause: Sendable, Equatable {
    case takeover
    case waitingInput
    case approval(tool: String, detail: String, arguments: String)
}

public struct AgentHistoryTurn: Sendable, Equatable {
    public var role: MessageRole
    public var text: String

    public init(role: MessageRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AgentLoopRequest: Sendable {
    public var endpoint: ModelEndpoint
    public var botName: String
    public var botTitle: String
    public var instructions: String
    public var memory: String
    public var sharedMemory: String
    public var skillCatalog: String
    public var homePath: String
    public var history: [AgentHistoryTurn]
    public var priorMessages: [ChatMessage]
    public var prompt: String
    public var tools: [ChatTool]
    public var maxSteps: Int
    public var depth: Int
    public var charBudget: Int
    /// Honest computer status for the system prompt (browser cookies, this Mac, or none).
    public var computerNote: String

    public init(
        endpoint: ModelEndpoint,
        botName: String,
        botTitle: String = "",
        instructions: String = "",
        memory: String = "",
        sharedMemory: String = "",
        skillCatalog: String = "",
        homePath: String = "",
        history: [AgentHistoryTurn] = [],
        priorMessages: [ChatMessage] = [],
        prompt: String,
        tools: [ChatTool],
        maxSteps: Int = 48,
        depth: Int = 0,
        charBudget: Int = 100_000,
        computerNote: String = ""
    ) {
        self.endpoint = endpoint
        self.botName = botName
        self.botTitle = botTitle
        self.instructions = instructions
        self.memory = memory
        self.sharedMemory = sharedMemory
        self.skillCatalog = skillCatalog
        self.homePath = homePath
        self.history = history
        self.priorMessages = priorMessages
        self.prompt = prompt
        self.tools = tools
        self.maxSteps = maxSteps
        self.depth = depth
        self.charBudget = charBudget
        self.computerNote = computerNote
    }
}

public struct AgentToolCallResult: Sendable {
    public var output: String
    public var blocks: [MessageBlock]
    public var pause: AgentPause?
    public var imageJPEGBase64: String?

    public init(
        output: String,
        blocks: [MessageBlock] = [],
        pause: AgentPause? = nil,
        imageJPEGBase64: String? = nil
    ) {
        self.output = output
        self.blocks = blocks
        self.pause = pause
        self.imageJPEGBase64 = imageJPEGBase64
    }
}

public struct AgentLoopResult: Sendable {
    public var text: String
    public var blocks: [MessageBlock]
    public var pause: AgentPause?
    public var inputTokens: Int
    public var outputTokens: Int
    public var steps: Int
    public var messages: [ChatMessage]
    public var compacted: Bool

    public init(
        text: String,
        blocks: [MessageBlock] = [],
        pause: AgentPause? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        steps: Int = 0,
        messages: [ChatMessage] = [],
        compacted: Bool = false
    ) {
        self.text = text
        self.blocks = blocks
        self.pause = pause
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.steps = steps
        self.messages = messages
        self.compacted = compacted
    }
}

public enum ContextCompactor {
    public static func encodedSize(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            total
                + message.role.count
                + (message.content?.count ?? 0)
                + message.toolCalls.reduce(0) { $0 + $1.name.count + $1.arguments.count }
                + (message.imageJPEGBase64?.count ?? 0)
        }
    }

    /// Keep system + newest turns; shrink tool payloads and stuffed user pastes.
    public static func compact(_ messages: [ChatMessage], budget: Int) -> (messages: [ChatMessage], compacted: Bool) {
        let original = encodedSize(messages)
        guard original > budget else { return (messages, false) }
        var copy = messages
        if copy.count > 4 {
            shrinkTools(&copy, keepLast: 6)
            if encodedSize(copy) > budget {
                shrinkTools(&copy, keepLast: 0)
            }
            if encodedSize(copy) > budget, copy.count > 8 {
                let head = copy.prefix(1)
                let tail = copy.suffix(6)
                let dropped = copy.count - 7
                let note = ChatMessage(
                    role: "user",
                    content: "[Earlier in this job, \(dropped) messages were compacted to stay within context.]"
                )
                copy = Array(head) + [note] + Array(tail)
            }
        }
        if encodedSize(copy) > budget {
            shrinkOversizedText(&copy)
        }
        return (copy, encodedSize(copy) < original)
    }

    private static func shrinkOversizedText(_ copy: inout [ChatMessage]) {
        for i in copy.indices {
            guard let content = copy[i].content, content.count > 2_500 else { continue }
            if copy[i].role == "user" || copy[i].role == "system" {
                copy[i].content = summarizePayload(content, head: 1_200, tail: 600)
            }
        }
    }

    private static func shrinkTools(_ copy: inout [ChatMessage], keepLast: Int) {
        let start = max(1, copy.count - keepLast)
        for i in 1..<start {
            if copy[i].role == "tool", let content = copy[i].content, content.count > 900 {
                copy[i].content = summarizePayload(content)
                copy[i].imageJPEGBase64 = nil
            }
            if copy[i].role == "assistant", copy[i].toolCalls.count > 0 {
                copy[i].toolCalls = copy[i].toolCalls.map { call in
                    var next = call
                    if next.arguments.count > 800 {
                        next.arguments = compactToolArguments(next.arguments)
                    }
                    return next
                }
            }
        }
    }

    /// Keep head + tail so the model still sees how a tool result started and ended.
    public static func summarizePayload(_ content: String, head: Int = 600, tail: Int = 300) -> String {
        if content.count <= head + tail + 80 { return content }
        let omitted = content.count - head - tail
        return String(content.prefix(head))
            + "\n…[summarized \(omitted) chars]…\n"
            + String(content.suffix(tail))
    }

    public static func isValidJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// LM Studio (and some other local servers) 500 when `tool_calls[].function.arguments` is not valid JSON.
    public static func ensureValidJSONArguments(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        if isValidJSON(trimmed) { return trimmed }
        return wrappedToolArguments(trimmed)
    }

    /// Shrink oversized tool-call JSON while remaining parseable. Never splice a summary into raw JSON.
    public static func compactToolArguments(_ arguments: String, limit: Int = 800) -> String {
        if arguments.count <= limit, isValidJSON(arguments) { return arguments }
        if var object = jsonObject(arguments) {
            shrinkJSONStringValues(&object)
            if let encoded = encodeJSON(object) {
                if encoded.count <= max(limit, 1_200) || isValidJSON(encoded) {
                    return encoded
                }
            }
        }
        return wrappedToolArguments(arguments)
    }

    static func wrappedToolArguments(_ arguments: String, previewLimit: Int = 400) -> String {
        let preview = String(arguments.prefix(previewLimit))
        let payload: [String: Any] = [
            "_compacted": true,
            "omitted": max(0, arguments.count - preview.count),
            "preview": preview,
        ]
        return encodeJSON(payload) ?? #"{"_compacted":true}"#
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    private static func shrinkJSONStringValues(_ object: inout [String: Any]) {
        for (key, raw) in object {
            if let string = raw as? String, string.count > 400 {
                object[key] = summarizePayload(string, head: 220, tail: 80)
            } else if var nested = raw as? [String: Any] {
                shrinkJSONStringValues(&nested)
                object[key] = nested
            }
        }
    }
}

public enum StreamText {
    /// Drop model chain-of-thought tags so they never show in chat.
    public static func visible(_ raw: String) -> String {
        var text = raw
        text = text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        text = text.replacing(/<think>[\s\S]*/, with: "")
        text = text.replacing(/<\/think>/, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OpenAI/Anthropic tool-calling loop. The store supplies tool execution.
public enum AgentLoop {
    public static func systemPrompt(for request: AgentLoopRequest, now: Date = .now) -> String {
        var lines: [String] = [
            "You are \(request.botName), a GrizzyBot agent running on this Mac.",
            utcDateLine(now: now),
            "You are a fully capable agent: think, use tools, and keep going until the user's request is done or you must wait for them.",
            "Be concise. Prefer tools over guessing. Never claim you wrote a file, ran a command, searched, signed in, or called a plugin unless a tool result says so.",
            "Shell runs inside a macOS seatbelt sandbox rooted at your home. Destructive shell and plugin writes pause for user approval unless always-allowed.",
            "Shell default timeout is \(Int(BotHomeStore.ShellTimeout.default))s. For multi-step research (curl loops, sleeps), pass timeout_seconds up to \(Int(BotHomeStore.ShellTimeout.max)) or split into shorter commands.",
            "Keep going across many tool rounds. If context is compacted, trust the remaining transcript and continue the job.",
            "Memory in this prompt is pinned standing rules plus the newest facts. Use search_memory for older facts. Use forget when a fact is wrong or outdated.",
            "read_file and list_files read the bot home, or an absolute/~ path on this Mac when the user named a folder (for example ~/.agents/skills). Prefer them over shell cat. write_file only writes the bot sandbox (Home path), not the user's Obsidian vault. MCP: mcp_list_tools once, then mcp_call. Toolport is a lazy gateway — list returns search/call meta-tools, not GitHub or Obsidian. Pass a catalog name like github__search_repositories as mcp_call's tool, or as arguments.name on toolport_call_tool (not id). Do not list or search Toolport again this turn after you have a name. Do not curl those APIs when an MCP tool exists. Shell ~ is the bot home, not the Mac home. Never claim an Obsidian write unless the tool result names obsidian_put_file (or that server's write tool) and status is ok.",
            AppConfig.keysHelp,
        ]
        let computer = request.computerNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if computer.isEmpty {
            lines.append("Computer: no live session is attached. Do not claim you can see or click a desktop until a screenshot tool succeeds.")
        } else {
            lines.append("Computer: \(computer)")
        }
        if !request.homePath.isEmpty {
            lines.append("Home path: \(request.homePath)")
        }
        if !request.botTitle.isEmpty {
            lines.append("Role: \(request.botTitle)")
        }
        let instructions = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            lines.append("Instructions from the user:\n\(instructions)")
        }
        let memory = request.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            lines.append("Durable memory:\n\(memory)")
        }
        let shared = request.sharedMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shared.isEmpty {
            lines.append("Shared workspace memory (every bot on this Mac):\n\(shared)")
        }
        let skills = request.skillCatalog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skills.isEmpty {
            lines.append(skills)
        }
        if request.depth > 0 {
            lines.append("You are a short-lived helper for one task. Do not spawn bots.")
        }
        return lines.joined(separator: "\n\n")
    }

    public static func utcDateLine(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let yesterday = formatter.string(from: now.addingTimeInterval(-86_400))
        return "Today is \(today) (UTC). Yesterday UTC is \(yesterday). Use these dates in search filters; do not call shell for the date."
    }

    public static let parallelSafeTools: Set<String> = [
        "web_search", "web_fetch", "read_file", "list_files", "search_memory",
        "computer_screenshot", "mcp_list_tools", "read_skill",
    ]

    public static func run(
        client: any ChatCompleting,
        request: AgentLoopRequest,
        onDelta: (@Sendable (String) -> Void)? = nil,
        onStep: (@Sendable (Int, Int) -> Void)? = nil,
        onTool: (@Sendable (String, String, AgentToolCallResult) -> Void)? = nil,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async throws -> AgentLoopResult {
        var messages: [ChatMessage] = [.system(systemPrompt(for: request))]
        if !request.priorMessages.isEmpty {
            messages.append(contentsOf: request.priorMessages.filter { $0.role != "system" })
        } else {
            for turn in request.history {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                switch turn.role {
                case .user:
                    messages.append(.user(text))
                case .bot:
                    messages.append(.assistant(text))
                case .system:
                    messages.append(.system(text))
                }
            }
        }
        messages.append(.user(request.prompt))

        var blocks: [MessageBlock] = []
        var inputTokens = 0
        var outputTokens = 0
        var lastText = ""
        var pause: AgentPause?
        var compacted = false
        let maxSteps = max(1, request.maxSteps)
        var tools = request.tools
        var webFails = 0

        func persistable() -> [ChatMessage] {
            Array(messages.drop(while: { $0.role == "system" }).prefix(200))
        }

        func modelRequest(
            onDelta: (@Sendable (String) -> Void)?,
            charBudget: Int
        ) async throws -> ChatCompletionResponse {
            var lastError: Error?
            var retryBudget = charBudget
            for attempt in 0..<ModelRequestRetry.maxAttempts {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: ModelRequestRetry.backoffNanoseconds(attempt: attempt - 1))
                    if let lastError, ModelRequestRetry.shouldCompactOnRetry(lastError) {
                        retryBudget = max(8_000, retryBudget * 3 / 4)
                        let tighter = ContextCompactor.compact(messages, budget: retryBudget)
                        messages = tighter.messages
                        if tighter.compacted { compacted = true }
                    }
                }
                let chatRequest = ChatCompletionRequest(
                    endpoint: request.endpoint,
                    messages: messages,
                    tools: tools
                )
                do {
                    if let onDelta {
                        return try await client.stream(chatRequest, onDelta: onDelta)
                    }
                    return try await client.complete(chatRequest)
                } catch {
                    lastError = error
                    if error is CancellationError { throw error }
                    if attempt + 1 < ModelRequestRetry.maxAttempts, ModelRequestRetry.isRetryable(error) {
                        continue
                    }
                    throw error
                }
            }
            throw lastError ?? LLMError.emptyResponse
        }

        for step in 1...maxSteps {
            if Task.isCancelled { throw CancellationError() }
            onStep?(step, maxSteps)
            let packed = ContextCompactor.compact(messages, budget: request.charBudget)
            messages = packed.messages
            if packed.compacted { compacted = true }

            let response: ChatCompletionResponse
            do {
                response = try await modelRequest(onDelta: onDelta, charBudget: request.charBudget)
            } catch {
                if !blocks.isEmpty {
                    let detail = error.localizedDescription
                    return AgentLoopResult(
                        text: "The model stopped responding (\(detail)). Tool results above may still be useful — ask me to continue.",
                        blocks: blocks,
                        pause: pause,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        steps: step,
                        messages: persistable(),
                        compacted: compacted
                    )
                }
                throw error
            }
            inputTokens += response.inputTokens
            outputTokens += response.outputTokens
            lastText = StreamText.visible(response.text)

            if !response.hasToolCalls {
                if !lastText.isEmpty {
                    messages.append(.assistant(lastText))
                }
                return AgentLoopResult(
                    text: lastText,
                    blocks: blocks,
                    pause: pause,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    steps: step,
                    messages: persistable(),
                    compacted: compacted
                )
            }

            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: response.text.isEmpty ? nil : response.text,
                    toolCalls: response.toolCalls
                )
            )

            let results = try await executeCalls(
                response.toolCalls,
                onTool: onTool,
                execute: execute
            )
            for (call, result) in zip(response.toolCalls, results) {
                blocks.append(contentsOf: result.blocks)
                let raw = result.output.isEmpty ? "(empty tool result)" : result.output
                var output = (call.name != "mcp_list_tools" && raw.count > 3_500)
                    ? ContextCompactor.summarizePayload(raw, head: 2_000, tail: 1_000)
                    : raw
                let vision = LLMRouting.supportsVisionImages(
                    provider: request.endpoint.provider,
                    model: request.endpoint.model
                )
                if result.imageJPEGBase64 != nil, !vision {
                    output += "\n[screenshot captured as pixels; this model cannot view images — use accessibility/UI text from the tool result.]"
                }
                messages.append(ChatMessage.tool(id: call.id, content: output))
                if let jpeg = result.imageJPEGBase64, vision {
                    messages.append(
                        ChatMessage(
                            role: "user",
                            content: "Screenshot from \(call.name).",
                            imageJPEGBase64: jpeg
                        )
                    )
                }
                if nameIsWeb(call.name) {
                    if isFailedWeb(output: result.output) {
                        webFails += 1
                    } else {
                        webFails = 0
                    }
                }
                if let nextPause = result.pause {
                    pause = nextPause
                    let text = lastText.isEmpty ? "Waiting on you to continue." : lastText
                    return AgentLoopResult(
                        text: text,
                        blocks: blocks,
                        pause: pause,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        steps: step,
                        messages: persistable(),
                        compacted: compacted
                    )
                }
            }
            if webFails >= 3, tools.contains(where: { $0.function.name == "web_search" || $0.function.name == "web_fetch" }) {
                tools.removeAll { $0.function.name == "web_search" || $0.function.name == "web_fetch" }
                messages.append(.user(
                    "Web search and fetch failed \(webFails) times. Those tools are disabled for the rest of this turn. Answer from this Mac (Settings → Connections → Keys, files, skills) or say you could not reach the web."
                ))
            }
        }

        return AgentLoopResult(
            text: lastText.isEmpty
                ? "I reached the step budget for this turn. Ask me to continue — I'll keep the full tool transcript."
                : lastText,
            blocks: blocks,
            pause: pause,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            steps: maxSteps,
            messages: persistable(),
            compacted: compacted
        )
    }

    private static func executeCalls(
        _ calls: [LLMToolCall],
        onTool: (@Sendable (String, String, AgentToolCallResult) -> Void)?,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async throws -> [AgentToolCallResult] {
        if calls.count > 1, calls.allSatisfy({ parallelSafeTools.contains($0.name) }) {
            return try await withThrowingTaskGroup(of: (Int, AgentToolCallResult).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        if Task.isCancelled { throw CancellationError() }
                        let result = await execute(call.name, call.arguments)
                        return (index, result)
                    }
                }
                var ordered = Array(repeating: AgentToolCallResult(output: ""), count: calls.count)
                for try await (index, result) in group {
                    ordered[index] = result
                    onTool?(calls[index].name, calls[index].arguments, result)
                }
                return ordered
            }
        }
        var out: [AgentToolCallResult] = []
        var paused = false
        for call in calls {
            if Task.isCancelled { throw CancellationError() }
            if paused {
                let skipped = AgentToolCallResult(output: "Skipped — waiting on earlier approval.")
                out.append(skipped)
                continue
            }
            let result = await execute(call.name, call.arguments)
            onTool?(call.name, call.arguments, result)
            out.append(result)
            if result.pause != nil { paused = true }
        }
        return out
    }

    private static func nameIsWeb(_ name: String) -> Bool {
        name == "web_search" || name == "web_fetch"
    }

    private static func isFailedWeb(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.hasPrefix("no results") { return true }
        if lowered.hasPrefix("search failed") || lowered.hasPrefix("search was blocked") { return true }
        if lowered.hasPrefix("fetch failed") { return true }
        if lowered.contains("do not retry") { return true }
        return false
    }
}
