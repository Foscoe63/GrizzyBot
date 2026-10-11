import Foundation

/// OpenClaw's best memory idea: before a long conversation is squeezed to fit, give the model one
/// quiet turn to write down what it would otherwise lose. Only `remember` is on offer, so the turn
/// cannot do anything else, and whatever it saves goes through the normal memory rules (secret
/// refusal, and the taint gate if the run has read outside content).
enum MemoryFlush {
    static let nudge = """
    The conversation is about to be shortened to fit the context window. Anything not saved will be lost.
    If there are durable facts, decisions, preferences, or open commitments above that you will need later, save each with remember (one short fact per call). If nothing is worth keeping, reply with exactly: NOTHING_TO_SAVE
    """

    static let maxSaves = 6

    /// Returns the tokens the flush spent. Failures are swallowed: a missed flush must never break the run.
    static func run(
        client: any ChatCompleting,
        endpoint: ModelEndpoint,
        messages: [ChatMessage],
        rememberTool: ChatTool,
        stallMs: Int,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async -> (input: Int, output: Int) {
        var convo = ContextCompactor.repairToolPairs(messages)
        convo.append(.user(nudge))
        let request = ChatCompletionRequest(endpoint: endpoint, messages: convo, tools: [rememberTool], stallMs: stallMs)
        guard let response = try? await client.complete(request) else { return (0, 0) }
        var saved = 0
        for call in response.toolCalls where call.name == "remember" && saved < maxSaves {
            if Task.isCancelled { break }
            _ = await execute(call.name, call.arguments)
            saved += 1
        }
        return (response.inputTokens, response.outputTokens)
    }
}
