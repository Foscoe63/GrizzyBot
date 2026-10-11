import Foundation

extension AppStore {
    static let companionSecretKey = "companion:token"

    func syncCompanion() async {
        guard appConfig.companionEnabled, delayScale >= 1, !headlessRoutineTick else {
            await companionServer.stop()
            return
        }
        var token = connectionSecrets[Self.companionSecretKey] ?? ""
        if token.isEmpty {
            token = WebhookSecret.generate()
            connectionSecrets[Self.companionSecretKey] = token
            save()
        }
        if await companionServer.isRunning, await companionServer.port == appConfig.companionPort {
            await companionServer.updateToken(token)
            return
        }
        try? await companionServer.start(
            port: appConfig.companionPort,
            allowNetwork: appConfig.companionAllowNetwork,
            token: token,
            backend: StoreCompanionBackend(store: self)
        )
    }

    /// Stop and start again, e.g. after switching between loopback and network listening.
    public func restartCompanion() async {
        await companionServer.stop()
        await syncCompanion()
    }

    public func companionToken() -> String? {
        let t = connectionSecrets[Self.companionSecretKey]
        return (t?.isEmpty == false) ? t : nil
    }

    @discardableResult
    public func rotateCompanionToken() -> String {
        let token = WebhookSecret.generate()
        connectionSecrets[Self.companionSecretKey] = token
        save()
        Task { await companionServer.updateToken(token) }
        return token
    }

    /// Addresses a phone can try, for showing in Settings: this Mac's hostnames and LAN address.
    public func companionAddresses() -> [String] {
        var out: [String] = []
        let host = ProcessInfo.processInfo.hostName
        if !host.isEmpty { out.append("http://\(host):\(appConfig.companionPort)") }
        for address in Self.localIPv4Addresses() { out.append("http://\(address):\(appConfig.companionPort)") }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    static func localIPv4Addresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

/// The store, seen through the companion's window: the control plane plus Allow/Deny on a waiting approval.
struct StoreCompanionBackend: CompanionBackend {
    private let control: StoreControlBackend
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        self.control = StoreControlBackend(store: store)
    }

    func listBots() async -> [ControlPlaneBot] { await control.listBots() }
    func status(bot: String) async -> String? { await control.status(bot: bot) }
    func recentMessages(bot: String, limit: Int) async -> [String]? { await control.recentMessages(bot: bot, limit: limit) }
    func search(query: String, bot: String?) async -> [String] { await control.search(query: query, bot: bot) }
    func send(bot: String, text: String, waitSeconds: Int) async -> String { await control.send(bot: bot, text: text, waitSeconds: waitSeconds) }
    func interrupt(bot: String) async -> String { await control.interrupt(bot: bot) }
    func setModel(bot: String, provider: String, model: String) async -> String { await control.setModel(bot: bot, provider: provider, model: model) }

    func pendingApprovals() async -> [CompanionApproval] {
        await MainActor.run {
            store.bots.compactMap { bot -> CompanionApproval? in
                guard store.pendingApprovalMessageId(botId: bot.id) != nil,
                      let pending = store.threads[store.threadKey(for: bot.id)]?.pendingTool else { return nil }
                let here = pending.tool != AppStore.secretRequestTool
                return CompanionApproval(botId: bot.id, botName: bot.name, tool: pending.tool, detail: pending.detail, answerableHere: here)
            }
        }
    }

    func answerApproval(bot: String, allow: Bool) async -> String {
        await MainActor.run {
            guard let b = store.findBot(bot) ?? store.bots.first(where: { $0.id == bot }) else { return "No such bot." }
            return store.answerPendingApproval(botId: b.id, decision: allow ? .allow : .deny)
                ? (allow ? "Allowed." : "Denied.")
                : "Nothing was waiting."
        }
    }
}
