import Foundation

extension AppStore {
    static let controlPlaneSecretKey = "controlplane:token"

    /// Starts or stops the MCP listener to match settings.
    func syncControlPlane() async {
        guard appConfig.controlPlaneEnabled, delayScale >= 1, !headlessRoutineTick else {
            await controlPlane.stop()
            return
        }
        var token = connectionSecrets[Self.controlPlaneSecretKey] ?? ""
        if token.isEmpty {
            token = WebhookSecret.generate()
            connectionSecrets[Self.controlPlaneSecretKey] = token
            save()
        }
        if await controlPlane.isRunning, await controlPlane.port == appConfig.controlPlanePort {
            await controlPlane.updateToken(token)
            return
        }
        try? await controlPlane.start(port: appConfig.controlPlanePort, token: token, backend: StoreControlBackend(store: self))
    }

    /// The current token, for showing in Settings so it can be pasted into an MCP client.
    public func controlPlaneToken() -> String? {
        let token = connectionSecrets[Self.controlPlaneSecretKey]
        return (token?.isEmpty == false) ? token : nil
    }

    @discardableResult
    public func rotateControlPlaneToken() -> String {
        let token = WebhookSecret.generate()
        connectionSecrets[Self.controlPlaneSecretKey] = token
        save()
        Task { await controlPlane.updateToken(token) }
        return token
    }

    /// The command that registers this server with Claude Code.
    public func controlPlaneClaudeCommand() -> String {
        "claude mcp add --transport http grizzybot http://127.0.0.1:\(appConfig.controlPlanePort)/mcp --header \"Authorization: Bearer \(controlPlaneToken() ?? "<token>")\""
    }

    func findBot(_ query: String) -> Bot? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bots.first { $0.id.lowercased() == q }
            ?? bots.first { $0.name.lowercased() == q }
            ?? bots.first { $0.name.lowercased().hasPrefix(q) }
    }
}

/// The store, seen through the narrow window the control plane is allowed to use.
struct StoreControlBackend: ControlPlaneBackend {
    private let store: AppStore
    // The store is main-actor bound; every call hops there. The reference itself never mutates.
    init(store: AppStore) { self.store = store }

    func listBots() async -> [ControlPlaneBot] {
        await MainActor.run {
            store.bots.filter { !$0.hidden }.map {
                ControlPlaneBot(id: $0.id, name: $0.name, title: $0.title, status: $0.status)
            }
        }
    }

    func status(bot: String) async -> String? {
        await MainActor.run {
            guard let bot = store.findBot(bot) else { return nil }
            let run = store.threads[store.threadKey(for: bot.id)]?.run
            let pending = store.pendingApprovalMessageId(botId: bot.id) != nil
            var text = "\(bot.name): \(run?.status.rawValue ?? "idle")"
            if pending { text += " — waiting for an approval in GrizzyBot" }
            return text
        }
    }

    func recentMessages(bot: String, limit: Int) async -> [String]? {
        await MainActor.run {
            guard let bot = store.findBot(bot) else { return nil }
            let messages = store.threads[store.threadKey(for: bot.id)]?.messages ?? []
            return messages.suffix(limit).compactMap { message -> String? in
                let text = message.firstText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, message.role != .system else { return nil }
                let who = message.role == .user ? "you" : bot.name
                return "[\(who)] \(String(text.prefix(2_000)))"
            }
        }
    }

    func search(query: String, bot: String?) async -> [String] {
        await MainActor.run {
            let targets = bot.flatMap { store.findBot($0) }.map { [$0] } ?? store.bots
            var out: [String] = []
            for target in targets {
                let hits = SessionSearch.search(docs: store.sessionDocs(for: target.id), query: query)
                if !hits.isEmpty { out.append("\(target.name):\n\(SessionSearch.render(Array(hits.prefix(5))))") }
            }
            return out
        }
    }

    func send(bot: String, text: String, waitSeconds: Int) async -> String {
        let found: (id: String, name: String)? = await MainActor.run {
            guard let b = store.findBot(bot) else { return nil }
            store.send(botId: b.id, text: text)
            return (b.id, b.name)
        }
        guard let found else { return "No bot matches “\(bot)”." }
        guard waitSeconds > 0 else { return "Sent to \(found.name)." }
        let done = await store.waitForRunCompletion(botId: found.id, timeout: TimeInterval(waitSeconds))
        return await MainActor.run {
            if store.pendingApprovalMessageId(botId: found.id) != nil {
                return "\(found.name) is waiting for an approval in GrizzyBot. Approvals can't be answered from here."
            }
            let reply = store.threads[store.threadKey(for: found.id)]?.messages.last { $0.role == .bot }?.firstText ?? ""
            if !done && reply.isEmpty { return "\(found.name) is still working. Read the chat later with grizzybot_read_chat." }
            return reply.isEmpty ? "\(found.name) finished without a text reply." : reply
        }
    }

    func interrupt(bot: String) async -> String {
        await MainActor.run {
            guard let b = store.findBot(bot) else { return "No bot matches “\(bot)”." }
            store.stopRun(botId: b.id)
            return "Stopped \(b.name)."
        }
    }

    func setModel(bot: String, provider: String, model: String) async -> String {
        await MainActor.run {
            guard let b = store.findBot(bot) else { return "No bot matches “\(bot)”." }
            store.setBotModel(b.id, choice: .catalog(provider: provider, modelId: model, label: model))
            return "\(b.name) now uses \(provider)/\(model)."
        }
    }
}
