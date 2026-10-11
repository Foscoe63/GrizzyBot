import Foundation

extension AppStore {
    /// Approvals that only a person can give, every time. Auto-approve, "always allow", and allow rules do
    /// not apply to them: they guard what a run that read outside content may do to things that outlive it.
    static let humanOnlyTools: Set<String> = [
        "memory.untrusted_write", "memory.untrusted_forget", "routine.untrusted", "delegate.lend", AppStore.secretRequestTool,
    ]

    /// Stops the run on an approval card regardless of the bot's auto-approve setting.
    func humanGate(tool: String, detail: String, argumentsJSON: String) -> AgentToolCallResult {
        AgentToolCallResult(
            output: "Need approval to run \(tool): \(detail)",
            blocks: [.approval(tool: tool, detail: detail, status: .pending)],
            pause: .approval(tool: tool, detail: detail, arguments: argumentsJSON)
        )
    }
}
