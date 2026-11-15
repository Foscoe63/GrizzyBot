import Foundation

/// Collects what an external agent did, from the callbacks that run off the main actor.
private final class ExternalAgentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String] = []
    private var refused: [String] = []

    func tool(_ title: String) { lock.lock(); tools.append(title); lock.unlock() }
    func refuse(_ title: String) { lock.lock(); refused.append(title); lock.unlock() }
    var snapshot: (tools: [String], refused: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (tools, refused)
    }
}

extension AppStore {
    /// Hands a coding job to an external agent in the bot's working folder. The person approves the
    /// job once, with its access level; the agent's own permission requests are then answered by
    /// `AcpPermissionPolicy`, never by the model.
    func runExternalAgent(
        bot: Bot,
        task: String,
        access rawAccess: String,
        agent agentId: String,
        argumentsJSON: String,
        approved: Bool,
        taint: RunTaint?
    ) async -> AgentToolCallResult {
        guard !task.isEmpty else { return AgentToolCallResult(output: "task is required") }
        guard let spec = ExternalAgentSpec.named(agentId, custom: externalAgents) else {
            let known = ExternalAgentSpec.all(custom: externalAgents).map(\.id).joined(separator: ", ")
            return AgentToolCallResult(output: "Unknown agent “\(agentId)”. Available: \(known).")
        }
        guard let folder = effectiveWorkingFolder(for: bot)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else {
            return AgentToolCallResult(output: "An external agent needs a working folder to run in, and this bot has none. Ask the person to set one.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return AgentToolCallResult(output: "The working folder \(folder) does not exist.")
        }
        let access = ExternalAgentAccess.parse(rawAccess)
        let summary = String(task.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        if let gated = gatedWrite(
            tool: "external_agent.run",
            detail: "\(spec.name) may \(access == .edit ? "read and edit files" : "read files") in \(folder): \(summary)",
            argumentsJSON: argumentsJSON,
            bot: bot,
            approved: approved
        ) {
            return gated
        }
        let allowed = bot.autoApprove || bot.alwaysAllowTools.contains("external_agent.run")
        let log = ExternalAgentLog()
        let client: AcpClient
        do {
            client = try AcpClient(command: spec.command, cwd: folder)
        } catch {
            return AgentToolCallResult(output: "\(spec.name) could not start: \(error.localizedDescription)")
        }
        do {
            try await client.start(cwd: folder)
            let result = try await client.prompt(
                task,
                onUpdate: { update in
                    if case .toolStarted(_, let title, _) = update { log.tool(title) }
                },
                onPermission: { request in
                    let choice = AcpPermissionPolicy.choose(request, access: access)
                    let ok = AcpPermissionPolicy.allows(toolKind: request.toolKind, access: access)
                    if !ok { log.refuse(request.toolTitle) }
                    return choice
                }
            )
            await client.close()
            // Whatever the agent read or wrote came from outside this conversation.
            taint?.mark(tool: "delegate_external")
            let seen = log.snapshot
            var output = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty { output = "(\(spec.name) returned no text)" }
            if output.count > 20_000 { output = String(output.prefix(20_000)) + "\n…(cut)" }
            if result.stopReason != "end_turn" { output += "\n[\(spec.name) stopped: \(result.stopReason)]" }
            if !seen.refused.isEmpty {
                output += "\n[\(spec.name) asked to do things it was not allowed to, and was refused: \(seen.refused.prefix(5).joined(separator: "; "))]"
            }
            return AgentToolCallResult(
                output: output,
                blocks: [
                    .approval(tool: "external_agent.run", detail: summary, status: allowed ? .alwaysAllowed : .allowed),
                    .card(lines: [
                        CardLine(k: "agent", v: spec.name),
                        CardLine(k: "folder", v: folder),
                        CardLine(k: "access", v: access.rawValue),
                        CardLine(k: "tools", v: "\(seen.tools.count)"),
                        CardLine(k: "stop", v: result.stopReason),
                    ]),
                ]
            )
        } catch {
            await client.close()
            return AgentToolCallResult(output: "\(spec.name) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Settings

/// What the settings Test button found out.
public struct ExternalAgentTestResult: Sendable, Equatable {
    public var ok: Bool
    public var text: String
}

extension AppStore {
    /// Adds a custom agent. Returns why it could not be added, or nil on success.
    @discardableResult
    public func addExternalAgent(name: String, commandLine: String) -> String? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "Give the agent a name." }
        let command = ExternalAgentSpec.parseCommandLine(commandLine)
        if let problem = ExternalAgentSpec.commandProblem(command) { return problem }
        if ExternalAgentSpec.named(label, custom: externalAgents) != nil, !label.isEmpty {
            return "An agent named “\(label)” already exists."
        }
        let id = ExternalAgentSpec.makeId(from: label, existing: externalAgents)
        externalAgents.append(ExternalAgentSpec(id: id, name: label, command: command))
        save()
        return nil
    }

    public func deleteExternalAgent(_ id: String) {
        guard !ExternalAgentSpec.isPreset(id) else { return }
        externalAgents.removeAll { $0.id == id }
        save()
    }

    /// Starts the agent, does the handshake and opens a session in a scratch folder, without sending a
    /// prompt, so nothing is spent and nothing is changed. Returns a one-line result for the person.
    public static func testExternalAgent(_ spec: ExternalAgentSpec) async -> ExternalAgentTestResult {
        if let problem = ExternalAgentSpec.commandProblem(spec.command) { return .init(ok: false, text: problem) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("grizzybot-acp-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .init(ok: false, text: "Could not make a scratch folder: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let client: AcpClient
        do {
            client = try AcpClient(command: spec.command, cwd: scratch.path)
        } catch {
            return .init(ok: false, text: error.localizedDescription)
        }
        do {
            let ready: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await client.start(cwd: scratch.path)
                    let name = await client.agentName
                    return name.isEmpty ? "ready" : "\(name) is ready"
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw AcpError.transport("No answer after 20 seconds. Is this an ACP agent?")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? "no answer"
            }
            await client.close()
            return .init(ok: true, text: ready)
        } catch {
            await client.close()
            return .init(ok: false, text: error.localizedDescription)
        }
    }
}
