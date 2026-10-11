import Foundation

extension AppStore {
    /// Every secret value this workspace holds, for exact-match leak checks.
    func knownSecretValues() -> [String] {
        var values: [String] = Array(connectionSecrets.values)
        let c = appConfig
        values += [c.composioConnectKey, c.composioApiKey, c.googleClientSecret, c.boxToken, c.ttsKey, c.sentryDSN, c.braveSearchKey]
            .compactMap { $0 }
        for entry in ModelCatalog.providers {
            let settings = modelProviderSettings(for: entry.provider)
            if let key = settings.apiKey { values.append(key) }
        }
        return values.filter { $0.count >= LeakScanner.minimumSecretLength }
    }

    /// Wraps one tool call: refuses to send a secret out, and scrubs a stored secret out of what comes back.
    public func guardedExecute(
        name: String,
        arguments: String,
        botId: String,
        runId: String? = nil,
        run: (String) async -> AgentToolCallResult
    ) async -> AgentToolCallResult {
        let started = Date()
        let secrets = knownSecretValues()
        // The bot wrote {{secret:NAME}}; the value is filled in here, after the leak check below has
        // looked at what the model actually produced, and scrubbed from the result afterwards.
        var finalArguments = arguments
        var resolved: [String: String] = [:]
        if !SecretPlaceholders.names(in: arguments).isEmpty {
            guard SecretPlaceholders.canInject(into: name) else {
                return AgentToolCallResult(output: "{{secret:…}} can only be used in web_fetch, plugin_call, MCP tool arguments and shell commands, not in \(name).")
            }
            let missing = SecretPlaceholders.names(in: arguments).filter { botSecretValue(botId: botId, name: $0) == nil }
            if !missing.isEmpty {
                return AgentToolCallResult(output: "No saved secret named \(missing.joined(separator: ", ")). Call request_secret to ask the person for it.")
            }
            if name != "shell" {
                do {
                    for placeholder in SecretPlaceholders.names(in: arguments) {
                        if let value = try await resolvedSecretValue(botId: botId, name: placeholder) { resolved[placeholder] = value }
                    }
                } catch {
                    return AgentToolCallResult(output: "Couldn't get the saved secret: \(error.localizedDescription)")
                }
            }
            if name == "shell" {
                // Never substituted into the text: the approval card shows $GRIZZY_SECRET_NAME and the
                // value reaches the process through its environment (see the shell tool).
                finalArguments = rewriteShellArguments(arguments)
            } else {
                finalArguments = SecretPlaceholders.substitute(arguments) { resolved[$0] }.text
            }
        }
        if LeakScanner.sendsOutside(tool: name) {
            let found = LeakScanner.findings(in: arguments, knownSecrets: secrets)
            if !found.isEmpty {
                recordAudit(
                    type: .secretLeakBlocked,
                    botId: botId,
                    tool: name,
                    reason: found.joined(separator: ", "),
                    allowed: false,
                    forwarded: false
                )
                return AgentToolCallResult(
                    output: "Blocked: this \(name) call contained \(found.joined(separator: ", ")). Nothing was sent. Secrets belong in Settings, never in a tool call; remove it and try again.",
                    blocks: [.card(lines: [CardLine(k: "blocked", v: "\(name) — would have sent \(found[0])")])]
                )
            }
        }
        var result = await run(finalArguments)
        if let runId, !appConfig.otlpEndpoint.isEmpty {
            let failed = result.output.lowercased().hasPrefix("blocked") || result.output.lowercased().contains(" failed")
            let span = TraceSpan(
                traceId: Tracing.traceId(forRun: runId),
                spanId: Tracing.newSpanId(),
                parentSpanId: Tracing.runSpanId(forRun: runId),
                name: "tool \(name)",
                start: started,
                end: Date(),
                ok: !failed,
                attributes: ["tool.name": name, "bot.id": botId]
            )
            let exporter = traceExporter
            Task { await exporter.record(span) }
        }
        if UntrustedContent.isExternal(tool: name) || name == "shell" {
            // Values read from 1Password at this moment are scrubbed too, though no store holds them.
            result.output = LeakScanner.redactKnown(result.output, knownSecrets: secrets + Array(resolved.values))
        }
        if ReauthDetector.needsReconnect(tool: name, output: result.output) {
            let target = ReauthDetector.target(arguments: arguments) ?? name
            result.output += "\n\nThis connection's sign-in has expired and only the person can renew it. A Reconnect card was shown. Do not retry; tell them and wait."
            result.blocks.append(.connect(name: target, initial: String(target.prefix(1)).uppercased(), color: "#B45309", status: .reconnect))
        }
        return result
    }
}

/// Spots a plugin failure that only the person can fix by signing in again, so the bot stops
/// retrying and a Reconnect card appears instead.
public enum ReauthDetector {
    private static let markers = [
        "sign-in expired", "sign in expired", "token expired", "token has expired", "invalid_grant",
        "re-authorize", "reauthorize", "reconnect from plugins", "sign in with google again",
        "authentication expired", "refresh token", "401 unauthorized", "(401)", "status 401",
    ]

    public static func needsReconnect(tool: String, output: String) -> Bool {
        guard tool == "plugin_call" || tool == "mcp_call" || tool == "destination_write" || tool.contains("__") else { return false }
        let lowered = output.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// The plugin a call was for, from its arguments (`slug`, `plugin`, `server`).
    public static func target(arguments: String) -> String? {
        let args = JSONValue.object(JSONValue.parseObject(arguments))
        for key in ["slug", "plugin", "server", "server_id"] {
            if let value = args.stringValue(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }
}

extension AppStore {
    /// Start sign-in again for a connection named on a Reconnect card.
    public func reconnectPlugin(named name: String) {
        let wanted = name.lowercased()
        if let match = connections.first(where: { $0.slug.lowercased() == wanted || $0.name.lowercased() == wanted }) {
            connect(slug: match.slug)
        } else {
            connect(slug: name)
        }
    }
}


extension AppStore {
    /// Rewrites the `command` field of a shell call so placeholders become environment references.
    func rewriteShellArguments(_ arguments: String) -> String {
        var object = JSONValue.parseObject(arguments)
        for key in ["command", "cmd"] {
            if case .string(let command)? = object[key] {
                object[key] = .string(SecretPlaceholders.rewriteForShell(command))
            }
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)), let text = String(data: data, encoding: .utf8) else { return arguments }
        return text
    }

    /// Secrets a shell command refers to by environment name.
    func shellSecretEnvironment(botId: String, command: String) async -> [String: String] {
        var values: [String: String] = [:]
        for name in botSecretNames(botId: botId) where command.contains(SecretPlaceholders.environmentName(for: name)) {
            if let value = try? await resolvedSecretValue(botId: botId, name: name) { values[name] = value }
        }
        return SecretPlaceholders.shellEnvironment(for: command, secretNames: botSecretNames(botId: botId)) { values[$0] }
    }

    /// The real value of a saved secret: the stored text, or — for an `op://` reference — whatever
    /// 1Password hands back right now.
    func resolvedSecretValue(botId: String, name: String) async throws -> String? {
        guard let stored = botSecretValue(botId: botId, name: name) else { return nil }
        guard OnePasswordCLI.isReference(stored) else { return stored }
        return try await secretReader.read(stored)
    }
}
