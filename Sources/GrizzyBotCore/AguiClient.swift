import Foundation

/// AG-UI HTTP client: POST RunAgentInput, read SSE events, return text + tool calls.
public enum AguiClient {
    public struct RunInput: Sendable {
        public var url: String
        public var headers: [String: String]
        public var threadId: String
        public var runId: String
        public var messages: [ChatMessage]
        public var tools: [ChatTool]
        public var stallMs: Int
        public var state: JSONValue

        public init(
            url: String,
            headers: [String: String] = [:],
            threadId: String,
            runId: String,
            messages: [ChatMessage],
            tools: [ChatTool],
            stallMs: Int = 60_000,
            state: JSONValue = .object([:])
        ) {
            self.url = url
            self.headers = headers
            self.threadId = threadId
            self.runId = runId
            self.messages = messages
            self.tools = tools
            self.stallMs = stallMs
            self.state = state
        }
    }

    public static func run(
        _ input: RunInput,
        session: URLSession = .shared,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChatCompletionResponse {
        guard let url = URL(string: input.url) else { throw LLMError.invalidURL(input.url) }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in input.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: input))
        ModelTransport.prepare(&request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
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
            throw LLMError.http(status, snippet)
        }

        var acc = AguiAccumulator()
        let monitor = StallMonitor(stallMs: input.stallMs)
        let watch = Task {
            try await monitor.watchUntilStall()
        }
        defer { watch.cancel() }
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                await monitor.touch()
                if let delta = acc.consume(line: line), !delta.isEmpty {
                    onDelta?(delta)
                }
                if acc.finished { break }
                if await monitor.isStalled() {
                    let snap = await monitor.snapshot()
                    throw StreamStallError(silentForMs: snap.silentForMs, chunks: snap.chunks)
                }
            }
        } catch is CancellationError {
            let snap = await monitor.snapshot()
            if snap.stalled {
                throw StreamStallError(silentForMs: snap.silentForMs, chunks: snap.chunks)
            }
            throw CancellationError()
        }
        if let error = acc.error {
            throw LLMError.http(-1, error)
        }
        return acc.result()
    }

    public static func parseSSEForTests(_ lines: [String]) throws -> ChatCompletionResponse {
        var acc = AguiAccumulator()
        for line in lines {
            _ = acc.consume(line: line)
        }
        if let error = acc.error { throw LLMError.http(-1, error) }
        return acc.result()
    }

    static func body(for input: RunInput) -> [String: Any] {
        [
            "threadId": input.threadId,
            "runId": input.runId,
            "state": input.state.any,
            "messages": input.messages.map { message -> [String: Any] in
                var item: [String: Any] = [
                    "id": message.toolCallId ?? Ids.new(),
                    "role": message.role,
                    "content": message.content ?? "",
                ]
                if !message.toolCalls.isEmpty {
                    item["toolCalls"] = message.toolCalls.map {
                        [
                            "id": $0.id,
                            "type": "function",
                            "function": [
                                "name": $0.name,
                                "arguments": $0.arguments,
                            ],
                        ]
                    }
                }
                if let toolCallId = message.toolCallId, message.role == "tool" {
                    item["toolCallId"] = toolCallId
                }
                return item
            },
            "tools": input.tools.map { tool in
                [
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": tool.function.parameters.any,
                ]
            },
        ]
    }
}

struct AguiAccumulator {
    var text = ""
    var toolCalls: [LLMToolCall] = []
    var currentToolId: String?
    var currentToolName: String?
    var currentArgs = ""
    var finished = false
    var error: String?
    var inputTokens = 0
    var outputTokens = 0
    var state: JSONValue = .object([:])

    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finished = true
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "TEXT_MESSAGE_START":
            if let content = object["content"] as? String, !content.isEmpty {
                text += content
                return content
            }
        case "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_CHUNK":
            let delta = object["delta"] as? String ?? object["content"] as? String ?? ""
            text += delta
            return delta
        case "TEXT_MESSAGE_END":
            break
        case "TOOL_CALL_START":
            flushTool()
            currentToolId = object["toolCallId"] as? String ?? Ids.new()
            currentToolName = object["toolCallName"] as? String
            if currentToolName == nil, let name = object["name"] as? String {
                currentToolName = name
            }
            currentArgs = ""
        case "TOOL_CALL_ARGS", "TOOL_CALL_CHUNK":
            currentArgs += object["delta"] as? String ?? object["args"] as? String ?? ""
        case "TOOL_CALL_END":
            flushTool()
        case "STATE_SNAPSHOT":
            if let snapshot = object["snapshot"] {
                state = JSONValue.from(snapshot)
            } else if let snapshot = object["state"] {
                state = JSONValue.from(snapshot)
            }
        case "STATE_DELTA":
            if let patch = object["delta"] ?? object["snapshot"] {
                state = state.merging(JSONValue.from(patch))
            }
        case "MESSAGES_SNAPSHOT", "STEP_STARTED", "STEP_FINISHED", "RUN_STARTED", "RAW", "CUSTOM":
            break
        case "RUN_FINISHED":
            flushTool()
            finished = true
        case "RUN_ERROR":
            error = object["message"] as? String ?? "AG-UI run error"
            if let code = object["code"] as? String, code == "AGENT_STREAM_STALLED" {
                error = object["message"] as? String ?? error
            }
            finished = true
        default:
            break
        }
        return nil
    }

    mutating func flushTool() {
        guard let id = currentToolId, let name = currentToolName, !name.isEmpty else {
            currentToolId = nil
            currentToolName = nil
            currentArgs = ""
            return
        }
        toolCalls.append(LLMToolCall(id: id, name: name, arguments: currentArgs.isEmpty ? "{}" : currentArgs))
        currentToolId = nil
        currentToolName = nil
        currentArgs = ""
    }

    func result() -> ChatCompletionResponse {
        ChatCompletionResponse(
            text: text,
            toolCalls: toolCalls,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            state: state
        )
    }
}

/// Drive an AG-UI endpoint the same way AgentLoop drives a local model: tools run here.
/// Frontend-tool dance: wait for `RUN_FINISHED`, execute tools locally, POST a second run with results + state.
public enum AguiRuntime {
    public static func run(
        input: AguiClient.RunInput,
        maxSteps: Int = 48,
        onDelta: (@Sendable (String) -> Void)? = nil,
        onTool: (@Sendable (String, String, AgentToolCallResult) -> Void)? = nil,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async throws -> AgentLoopResult {
        var messages = input.messages
        var blocks: [MessageBlock] = []
        var lastText = ""
        var pause: AgentPause?
        var inputTokens = 0
        var outputTokens = 0
        var state = input.state
        let cap = max(1, maxSteps)

        for step in 1...cap {
            if Task.isCancelled { throw CancellationError() }
            var turn = input
            turn.messages = messages
            turn.runId = "\(input.runId)-\(step)"
            turn.state = state
            let response: ChatCompletionResponse
            do {
                response = try await AguiClient.run(turn, onDelta: onDelta)
            } catch let stall as StreamStallError {
                throw LLMError.stalled(silentForMs: stall.silentForMs, chunks: stall.chunks)
            }
            inputTokens += response.inputTokens
            outputTokens += response.outputTokens
            state = response.state
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
                    messages: Array(messages.prefix(200))
                )
            }
            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: response.text.isEmpty ? nil : response.text,
                    toolCalls: response.toolCalls
                )
            )
            for call in response.toolCalls {
                let result = await execute(call.name, call.arguments)
                onTool?(call.name, call.arguments, result)
                blocks.append(contentsOf: result.blocks)
                if let next = result.pause {
                    pause = next
                    messages.append(.tool(id: call.id, content: result.output))
                    return AgentLoopResult(
                        text: lastText,
                        blocks: blocks,
                        pause: pause,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        steps: step,
                        messages: Array(messages.prefix(200))
                    )
                }
                messages.append(.tool(id: call.id, content: result.output))
            }
        }
        return AgentLoopResult(
            text: lastText.isEmpty ? "Reached the AG-UI step limit." : lastText,
            blocks: blocks,
            pause: pause,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            steps: cap,
            messages: Array(messages.prefix(200)),
            failed: true,
            failureReason: "step budget"
        )
    }
}
