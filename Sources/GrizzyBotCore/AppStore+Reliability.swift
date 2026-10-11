import Foundation

// Model reliability: fallback chain, light-model routing, and scoped allow rules.
extension AppStore {
    /// Builds an endpoint (and refreshes an OAuth token if the provider uses one) for a provider/model.
    func resolveEndpoint(provider: String?, modelId: String?) async throws -> ModelEndpoint {
        let settings = modelProviderSettings(for: provider ?? ModelCatalog.defaultProvider)
        if chatCompleter != nil {
            return (try? LLMRouting.endpoint(
                provider: provider,
                modelId: modelId,
                apiKey: settings.apiKey,
                baseUrl: settings.baseUrl
            )) ?? ModelEndpoint(
                provider: provider ?? "injected",
                model: modelId ?? "test",
                baseURL: "https://localhost/v1",
                apiKey: "local"
            )
        }
        var key = settings.apiKey
        if let token = await DeviceCodeAuth.resolveAccessToken(
            apiKey: settings.apiKey,
            oauthJSON: settings.oauthJSON,
            provider: provider ?? ""
        ) {
            key = token
        }
        return try LLMRouting.endpoint(
            provider: provider,
            modelId: modelId,
            apiKey: key,
            baseUrl: settings.baseUrl
        )
    }

    /// The bot's fallback models, resolved. One that cannot be built (no key) is skipped, not fatal.
    func resolveFallbacks(for bot: Bot, excluding primary: ModelEndpoint) async -> [ModelFallback] {
        var out: [ModelFallback] = []
        for choice in bot.fallbackModels {
            guard let endpoint = try? await resolveEndpoint(provider: choice.provider, modelId: choice.modelId),
                  !(endpoint.provider == primary.provider && endpoint.model == primary.model)
            else { continue }
            let client: any ChatCompleting = chatCompleter ?? Self.defaultClient(for: choice.provider)
            out.append(ModelFallback(endpoint: endpoint, client: client))
        }
        return out
    }

    // MARK: - Settings

    public func setBotLightModel(_ botId: String, choice: BotModelChoice) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        switch choice {
        case .workspaceDefault: bots[idx].lightModel = nil
        case .catalog(let provider, let modelId, _): bots[idx].lightModel = ModelChoice(provider: provider, modelId: modelId)
        }
        bots[idx].updatedAt = .now
        save()
    }

    public func addBotFallback(_ botId: String, choice: BotModelChoice) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }),
              case .catalog(let provider, let modelId, _) = choice else { return }
        let item = ModelChoice(provider: provider, modelId: modelId)
        guard !bots[idx].fallbackModels.contains(item) else { return }
        bots[idx].fallbackModels.append(item)
        bots[idx].updatedAt = .now
        save()
    }

    public func removeBotFallback(_ botId: String, choice: ModelChoice) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].fallbackModels.removeAll { $0 == choice }
        bots[idx].updatedAt = .now
        save()
    }

    public func removeAllowRule(_ botId: String, ruleId: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].allowRules.removeAll { $0.id == ruleId }
        bots[idx].updatedAt = .now
        save()
    }

    public func removeAlwaysAllowTool(_ botId: String, tool: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].alwaysAllowTools.removeAll { $0 == tool }
        bots[idx].updatedAt = .now
        save()
    }
}

// Answering an approval from outside the chat (a notification button).
extension AppStore {
    /// The newest approval card in this bot's chat that is still waiting.
    public func pendingApprovalMessageId(botId: String) -> String? {
        guard let thread = threads[threadKey(for: botId)] else { return nil }
        for message in thread.messages.reversed() {
            for block in message.blocks {
                if case .approval(_, _, .pending) = block { return message.id }
            }
        }
        return nil
    }

    @discardableResult
    public func answerPendingApproval(botId: String, decision: ApprovalDecision) -> Bool {
        guard let id = pendingApprovalMessageId(botId: botId) else { return false }
        answerApproval(botId: botId, messageId: id, decision: decision)
        // The live tool card and the final card can both show the same request; settle the twin
        // without running the tool a second time.
        let key = threadKey(for: botId)
        if var thread = threads[key] {
            let status: ApprovalStatus = decision == .deny ? .denied : (decision == .alwaysAllow ? .alwaysAllowed : .allowed)
            var changed = false
            for m in thread.messages.indices {
                for b in thread.messages[m].blocks.indices {
                    if case .approval(let tool, let detail, .pending) = thread.messages[m].blocks[b] {
                        thread.messages[m].blocks[b] = .approval(tool: tool, detail: detail, status: status)
                        changed = true
                    }
                }
            }
            if changed { threads[key] = thread }
        }
        return true
    }
}

extension AppStore {
    /// The bot's newest reply in its current chat, or empty.
    public func lastBotReply(botId: String) -> String {
        threads[threadKey(for: botId)]?.messages.last { $0.role == .bot }?.firstText ?? ""
    }
}
