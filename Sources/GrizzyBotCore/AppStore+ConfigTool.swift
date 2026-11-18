import Foundation

// `config_manage`: a bot changes a handful of safe app settings for the person. Every change stops on an
// approval card that only a person can answer, and every change lands in the config history so it can be
// undone from Settings.
extension AppStore {
    func configManage(bot: Bot, argumentsJSON: String, approved: Bool, taint: RunTaint?) -> AgentToolCallResult {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        func value(_ key: String) -> String { (args.stringValue(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch value("action").lowercased() {
        case "list", "":
            return AgentToolCallResult(output: "Settings you can change:\n" + ConfigAssistant.describe(appConfig))
        case "get":
            guard let current = ConfigAssistant.value(of: value("key"), in: appConfig) else {
                return AgentToolCallResult(output: ConfigAssistant.Failure.unknownKey(value("key")).localizedDescription)
            }
            return AgentToolCallResult(output: "\(value("key")) = \(current)")
        case "history":
            let recent = configHistory().suffix(10).reversed()
            guard !recent.isEmpty else { return AgentToolCallResult(output: "No settings changes recorded yet.") }
            return AgentToolCallResult(output: recent.map { "- [\($0.id)] \($0.at.formatted(date: .abbreviated, time: .shortened)) \($0.source): \($0.summary)" }.joined(separator: "\n"))
        case "set":
            let key = value("key"), new = value("value")
            let next: AppConfig
            do { next = try ConfigAssistant.applying(key: key, value: new, to: appConfig) } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }
            if next == appConfig { return AgentToolCallResult(output: "\(key) is already \(new).") }
            if !approved {
                let why = taint?.isTainted == true ? " (this run has read outside content)" : ""
                return humanGate(tool: "config.change", detail: "Change \(key) from \(ConfigAssistant.value(of: key, in: appConfig) ?? "?") to \(new)\(why)", argumentsJSON: argumentsJSON)
            }
            saveAppConfig(next, source: "assistant")
            return AgentToolCallResult(
                output: "Changed \(key) to \(new). It is in the settings history and can be undone there.",
                blocks: [.card(lines: [CardLine(k: "setting", v: key), CardLine(k: "now", v: new)])]
            )
        case "revert":
            guard let change = configHistory().first(where: { $0.id == value("id") }), change.revertible else {
                return AgentToolCallResult(output: "No revertible change with that id. Use action=history.")
            }
            if !approved {
                return humanGate(tool: "config.change", detail: "Undo the settings change: \(change.summary)", argumentsJSON: argumentsJSON)
            }
            return AgentToolCallResult(output: revertConfigChange(id: change.id) ? "Undone." : "That change could not be undone.")
        default:
            return AgentToolCallResult(output: "action must be list, get, set, history, or revert.")
        }
    }
}

// `workflow_run`: run one of the saved workflows. A workflow runs unattended, so a step that would need an
// approval fails instead of waiting, and a step may only use tools this bot already has.
extension AppStore {
    public func workflows() -> [WorkflowDefinition] { WorkflowLibrary.load(root: userPersistence.root) }

    private struct StoreWorkflowExecutor: WorkflowNodeExecutor {
        let store: AppStore
        let botId: String
        let runId: String
        let endpoint: ModelEndpoint
        let client: any ChatCompleting
        let allowedTools: Set<String>
        let taint: RunTaint

        func execute(_ node: WorkflowNode, args: [String: String], prompt: String?) async throws -> JSONValue {
            switch node.kind {
            case .tool:
                let name = node.tool ?? ""
                guard allowedTools.contains(name), name != "workflow_run", name != "config_manage" else {
                    throw WorkflowError.invalid("this bot can't use \(name) in a workflow")
                }
                let json = (try? JSONEncoder().encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let result = await store.guardedExecute(name: name, arguments: json, botId: botId, runId: runId) { final in
                    await store.executeAgentTool(name: name, argumentsJSON: final, botId: botId, depth: 1, endpoint: endpoint, client: client, taint: taint)
                }
                if UntrustedContent.taints(tool: name) { taint.mark(tool: name) }
                if result.pause != nil { throw WorkflowError.invalid("\(name) needs an approval, which a workflow can't wait for") }
                if let failure = ToolEnvelope.classify(output: result.output) { throw WorkflowError.invalid("\(name) failed (\(failure.kind.rawValue)): \(result.output.prefix(200))") }
                return .string(result.output)
            case .inference:
                var question = prompt ?? ""
                if !node.options.isEmpty { question += "\n\nAnswer with exactly one of: " + node.options.joined(separator: ", ") + "." }
                let request = ChatCompletionRequest(endpoint: endpoint, messages: [.system("You are one step of an automated workflow. Be concise."), ChatMessage(role: "user", content: question)], timeout: node.timeoutSeconds)
                let reply = try await client.complete(request).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !node.options.isEmpty {
                    guard let pick = node.options.first(where: { reply.lowercased().contains($0.lowercased()) }) else {
                        throw WorkflowError.invalid("the model's answer wasn't one of the options")
                    }
                    return .string(pick)
                }
                return .string(reply)
            case .http:
                guard let url = URL(string: args["url"] ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw WorkflowError.invalid("http steps need an http(s) url")
                }
                let leaks = LeakScanner.findings(in: (args["url"] ?? "") + (args["body"] ?? ""), knownSecrets: await store.knownSecretValues())
                guard leaks.isEmpty else { throw WorkflowError.invalid("blocked: the request contained \(leaks.joined(separator: ", "))") }
                var request = URLRequest(url: url, timeoutInterval: node.timeoutSeconds)
                request.httpMethod = (args["method"] ?? "GET").uppercased()
                if let body = args["body"], !body.isEmpty { request.httpBody = Data(body.utf8) }
                let (data, response) = try await URLSession.shared.data(for: request)
                taint.mark(tool: "web_fetch")
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw WorkflowError.invalid("http \(status)") }
                return .string(UntrustedContent.wrap(String(String(decoding: data, as: UTF8.self).prefix(20_000)), tool: "web_fetch"))
            }
        }
    }

    /// Runs a saved workflow as a bot, for the Run button. Uses the same checks and audit as the tool.
    public func runWorkflow(id: String, input: [String: String], botId: String) async -> String {
        guard let bot = bots.first(where: { $0.id == botId }) else { return "Pick a bot first." }
        var args: [String: JSONValue] = ["id": .string(id)]
        args["input"] = .object(input.mapValues { .string($0) })
        guard let data = try? JSONEncoder().encode(JSONValue.object(args)), let json = String(data: data, encoding: .utf8) else { return "Couldn't build the request." }
        return await workflowRun(bot: bot, argumentsJSON: json).output
    }

    func workflowRun(bot: Bot, argumentsJSON: String) async -> AgentToolCallResult {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        let all = workflows()
        let wanted = (args.stringValue("id") ?? args.stringValue("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.isEmpty || (args.stringValue("action") ?? "") == "list" {
            guard !all.isEmpty else { return AgentToolCallResult(output: "No workflows saved. They live as JSON files in the workflows folder of your GrizzyBot folder.") }
            return AgentToolCallResult(output: all.map { "- \($0.id): \($0.name) — needs \($0.inputs.keys.sorted().joined(separator: ", ").isEmpty ? "no input" : $0.inputs.keys.sorted().joined(separator: ", "))" }.joined(separator: "\n"))
        }
        guard let def = all.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            return AgentToolCallResult(output: "No workflow named “\(wanted)”. Use action=list.")
        }
        let missing = WorkflowValidator.missingRequirements(def, enabledTools: bot.enabledTools, secretNames: botSecretNames(botId: bot.id))
        if !missing.isEmpty { return AgentToolCallResult(output: "“\(def.name)” can't run yet — " + missing.joined(separator: "; ") + ".") }
        var input: [String: String] = [:]
        if case .object(let o)? = JSONValue.parseObject(argumentsJSON)["input"] { for (k, v) in o { input[k] = WorkflowBindings.text(v) } }
        do {
            let endpoint = try await resolveEndpoint(provider: modelProvider, modelId: modelId)
            let client: any ChatCompleting = chatCompleter ?? Self.defaultClient(for: modelProvider)
            let runId = Ids.new()
            let executor = StoreWorkflowExecutor(store: self, botId: bot.id, runId: runId, endpoint: endpoint, client: client, allowedTools: Set(bot.enabledTools), taint: RunTaint())
            let record = await WorkflowRunner.run(def, input: input, executor: executor)
            recordAudit(type: .agentInvoked, botId: bot.id, tool: "workflow_run", reason: "workflow \(def.id): \(record.succeeded ? "ok" : "stopped")", allowed: true, forwarded: true)
            var out = record.summary
            if !record.output.isEmpty { out += "\n\nResult:\n" + record.output.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }
            return AgentToolCallResult(output: out, blocks: [.card(lines: record.steps.map { CardLine(k: $0.nodeId, v: $0.status.rawValue) })])
        } catch {
            return AgentToolCallResult(output: "Couldn't start the workflow: \(error.localizedDescription)")
        }
    }
}
