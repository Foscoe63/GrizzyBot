import Foundation
import Observation

// Split out of Store.swift by its MARK sections; behavior is unchanged.
extension AppStore {
    // MARK: - Plugins

    public func openPlugins() {
        pluginsOpen = true
        Task { await refreshPluginCatalog() }
    }

    public func refreshPluginCatalog() async {
        mergeCatalog(ConnectionCatalog.defaults)
        if liveComposio() != nil {
            await browseComposioCatalog(query: "")
            await refreshComposioStatus(slugs: connections.map(\.slug).prefix(40).map { $0 })
            for item in connections where item.connected && item.viaComposio && GoogleOAuth.isGooglePlugin(item.slug) {
                await refreshComposioAccountChoices(slug: item.slug)
            }
        } else {
            composioCatalog = []
            composioCatalogError = nil
        }
    }

    public func browseComposioCatalog(query: String) async {
        guard let composio = liveComposio() else {
            composioCatalog = []
            composioCatalogError = nil
            composioCatalogLoading = false
            return
        }
        composioCatalogLoading = true
        composioCatalogError = nil
        do {
            let items = try await composio.listCatalog(query: query)
            composioCatalog = items
            mergeCatalog(items, addingNew: false)
        } catch {
            composioCatalogError = error.localizedDescription
            composioCatalog = []
        }
        composioCatalogLoading = false
    }

    @discardableResult
    public func addToolkit(_ item: ConnectionItem) -> ConnectionItem? {
        let slug = item.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty else { return nil }
        var copy = item
        copy.slug = slug
        if copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.name = slug
        }
        mergeCatalog([copy])
        save()
        return connections.first(where: { $0.slug == slug })
    }

    @discardableResult
    public func addToolkit(slug: String, name: String? = nil) -> ConnectionItem? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return addToolkit(ConnectionItem(
            slug: trimmed.lowercased(),
            name: name ?? trimmed,
            blurb: "Composio toolkit"
        ))
    }

    func mergeCatalog(_ incoming: [ConnectionItem], addingNew: Bool = true) {
        var bySlug: [String: ConnectionItem] = [:]
        for item in connections { bySlug[item.slug] = item }
        var ordered: [ConnectionItem] = []
        var seen = Set<String>()
        for item in incoming {
            if let existing = bySlug[item.slug] {
                var merged = existing
                merged.name = item.name.isEmpty ? merged.name : item.name
                if merged.blurb.isEmpty { merged.blurb = item.blurb }
                if merged.logo == nil { merged.logo = item.logo }
                if merged.domain == nil { merged.domain = item.domain }
                ordered.append(merged)
                seen.insert(item.slug)
            } else if addingNew {
                ordered.append(item)
                seen.insert(item.slug)
            }
        }
        for item in connections where !seen.contains(item.slug) {
            ordered.append(item)
        }
        connections = ordered
    }

    private func refreshComposioStatus(slugs: [String]) async {
        guard let composio = liveComposio() else { return }
        for slug in slugs {
            let ok = (try? await composio.isConnected(slug)) ?? false
            if let idx = connections.firstIndex(where: { $0.slug == slug }) {
                if ok {
                    connections[idx].connected = true
                    connections[idx].viaComposio = true
                    connections[idx].accountLabel = connections[idx].accountLabel ?? "Composio"
                    connectionSecrets[slug] = ComposioClient.composioTokenSentinel
                } else if connections[idx].viaComposio {
                    connections[idx].connected = false
                    connections[idx].accountLabel = nil
                    connectionSecrets[slug] = nil
                }
            }
        }
        save()
    }

    /// Pull one toolkit's live Composio status into local plugin state (used by plugin_call).
    @discardableResult
    public func syncComposioConnection(slug: String) async -> Bool {
        guard liveComposio() != nil else { return false }
        let resolved = resolvePluginSlug(slug)
        if connections.first(where: { $0.slug == resolved }) == nil {
            _ = addToolkit(slug: resolved)
        }
        await refreshComposioStatus(slugs: [resolved])
        return connections.first(where: { $0.slug == resolved })?.connected == true
    }

    public func connect(slug: String, token: String? = nil) {
        let slug = resolvePluginSlug(slug)
        guard !connectionPending.contains(slug) else { return }
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if connections.first(where: { $0.slug == slug })?.noAuth == true {
                if let idx = connections.firstIndex(where: { $0.slug == slug }) {
                    connections[idx].connected = true
                    connections[idx].accountLabel = slug
                }
                save()
                return
            }
            // Prefer direct Google OAuth when Client ID/Secret are configured (bypasses Composio).
            if GoogleOAuth.isGooglePlugin(slug), liveGoogleOAuth() != nil {
                startGoogleOAuth(slugs: [slug])
                return
            }
            if liveComposio() != nil {
                startComposioOAuth(slug: slug)
                return
            }
            connectingSlug = slug
            pluginError = nil
            return
        }
        connectionPending.insert(slug)
        pluginTasks[slug]?.cancel()
        pluginError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let account = try await self.pluginClient.verify(slug: slug, token: trimmed)
                if let idx = self.connections.firstIndex(where: { $0.slug == slug }) {
                    self.connections[idx].connected = true
                    self.connections[idx].accountLabel = account.label
                    self.connections[idx].viaComposio = false
                }
                self.connectionSecrets[slug] = account.token
                self.connectingSlug = nil
            } catch {
                self.pluginError = error.localizedDescription
            }
            self.connectionPending.remove(slug)
            self.save()
            self.pluginTasks.removeValue(forKey: slug)
        }
        pluginTasks[slug] = task
    }

    /// One Google sign-in for Gmail + Calendar + Sheets + Docs + Drive.
    public func connectGoogleSuite() {
        startGoogleOAuth(slugs: GoogleOAuth.allGoogleSlugs)
    }

    /// Open the paste-token sheet instead of (or after) browser OAuth.
    public func promptPluginToken(slug: String) {
        pluginTasks[slug]?.cancel()
        connectionPending.remove(slug)
        if oauthWaitSlug == slug { oauthWaitSlug = nil }
        pluginAuthURL = nil
        connectingSlug = slug
        pluginError = nil
    }

    private static let googleTokenSentinel = "google-oauth"

    private func startGoogleOAuth(slugs: [String]) {
        guard let google = liveGoogleOAuth() else { return }
        let clientId = (appConfig.googleClientId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = (appConfig.googleClientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard googleOAuthClient != nil || (!clientId.isEmpty && !clientSecret.isEmpty) else {
            pluginError = GoogleOAuthError.missingCredentials.localizedDescription
            return
        }
        let targetSlugs = slugs.filter { GoogleOAuth.isGooglePlugin($0) }
        guard !targetSlugs.isEmpty else { return }
        for slug in targetSlugs {
            connectionPending.insert(slug)
            pluginTasks[slug]?.cancel()
        }
        pluginError = nil
        oauthWaitSlug = targetSlugs.first
        let waitKey = targetSlugs.joined(separator: ",")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var scopes = GoogleOAuth.scopes(for: targetSlugs)
                if let existing = GoogleOAuth.decodeCredential(self.connectionSecrets[GoogleOAuth.credentialSecretKey]) {
                    for scope in existing.scopes where !scopes.contains(scope) {
                        scopes.append(scope)
                    }
                }
                let cred = try await google.authorize(
                    clientId: clientId.isEmpty ? "test-client" : clientId,
                    clientSecret: clientSecret.isEmpty ? "test-secret" : clientSecret,
                    scopes: scopes
                )
                self.applyGoogleCredential(cred, slugs: targetSlugs)
                self.pluginError = nil
            } catch {
                self.pluginError = error.localizedDescription
            }
            for slug in targetSlugs {
                self.connectionPending.remove(slug)
                self.pluginTasks.removeValue(forKey: slug)
            }
            if self.oauthWaitSlug == targetSlugs.first { self.oauthWaitSlug = nil }
            self.pluginAuthURL = nil
            self.save()
            _ = waitKey
        }
        for slug in targetSlugs {
            pluginTasks[slug] = task
        }
    }

    private func applyGoogleCredential(_ cred: GoogleOAuthCredential, slugs: [String]) {
        if let encoded = GoogleOAuth.encodeCredential(cred) {
            connectionSecrets[GoogleOAuth.credentialSecretKey] = encoded
        }
        let label = cred.email ?? "Google"
        for slug in slugs {
            if connections.first(where: { $0.slug == slug }) == nil {
                _ = addToolkit(slug: slug)
            }
            if let idx = connections.firstIndex(where: { $0.slug == slug }) {
                connections[idx].connected = true
                connections[idx].viaComposio = false
                connections[idx].accountLabel = label
            }
            connectionSecrets[slug] = Self.googleTokenSentinel
        }
    }

    private func liveGoogleAccessToken(for slug: String) async throws -> String? {
        guard GoogleOAuth.isGooglePlugin(slug) else { return nil }
        guard connectionSecrets[slug] == Self.googleTokenSentinel else { return nil }
        guard var cred = GoogleOAuth.decodeCredential(connectionSecrets[GoogleOAuth.credentialSecretKey]) else {
            throw PluginError.rejected(
                "Google sign-in is missing for \(slug). Open Plugins → Sign in with Google, then try again."
            )
        }
        if cred.isExpired {
            guard let google = liveGoogleOAuth(),
                  let clientId = appConfig.googleClientId,
                  let clientSecret = appConfig.googleClientSecret
            else {
                throw PluginError.rejected(
                    "Google token expired and Client ID/Secret are missing. Re-save them in Settings → Google, then Sign in with Google."
                )
            }
            do {
                cred = try await google.refresh(cred, clientId: clientId, clientSecret: clientSecret)
            } catch {
                throw PluginError.rejected(
                    "Google sign-in expired (\(error.localizedDescription)). Open Plugins → Sign in with Google again."
                )
            }
            if let encoded = GoogleOAuth.encodeCredential(cred) {
                connectionSecrets[GoogleOAuth.credentialSecretKey] = encoded
                save()
            }
        }
        return cred.access
    }

    private func startComposioOAuth(slug: String) {
        guard let composio = liveComposio() else { return }
        let resolved = resolvePluginSlug(slug)
        connectionPending.insert(resolved)
        pluginError = nil
        oauthWaitSlug = resolved
        pluginTasks[resolved]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if (try? await composio.isConnected(resolved)) == true {
                    if let idx = self.connections.firstIndex(where: { $0.slug == resolved }) {
                        self.connections[idx].connected = true
                        self.connections[idx].viaComposio = true
                        self.connections[idx].accountLabel = "Signed in"
                    }
                    self.connectionSecrets[resolved] = ComposioClient.composioTokenSentinel
                    self.pluginError = nil
                    self.pluginAuthURL = nil
                } else {
                    let entity = self.session?.userId ?? self.activeBotId ?? "default"
                    let url = try await composio.authorizeURL(for: resolved, userId: entity)
                    let setup = ComposioClient.isAuthConfigSetupURL(url)
                        || ComposioClient.requiresCustomAuthConfig(resolved)
                    let hint: String? = {
                        if ComposioClient.isAuthConfigSetupURL(url) {
                            return ComposioClient.authSetupMessage(for: resolved, url: url)
                        }
                        if ComposioClient.requiresCustomAuthConfig(resolved) {
                            // Show checklist while polling — X often fails with “weren’t able to give access”.
                            return """
                            Finish sign-in in the browser. If X says you weren’t able to give access, the Auth Config or callback URL is wrong — see https://composio.dev/auth/twitter (callback must be https://backend.composio.dev/api/v1/auth-apps/add).
                            """
                        }
                        return nil
                    }()
                    self.presentPluginAuthURL(url, setupHint: hint)
                    if setup && ComposioClient.isAuthConfigSetupURL(url) {
                        // Dashboard setup link — user must finish Auth Config before OAuth works.
                        self.connectionPending.remove(resolved)
                        self.oauthWaitSlug = nil
                        self.save()
                        self.pluginTasks.removeValue(forKey: resolved)
                        return
                    }
                    var connected = false
                    for _ in 0..<24 {
                        try? await Task.sleep(for: .seconds(max(0.05, 2.5 * self.delayScale)))
                        if Task.isCancelled { break }
                        if (try? await composio.isConnected(resolved)) == true {
                            connected = true
                            break
                        }
                    }
                    if connected {
                        if let idx = self.connections.firstIndex(where: { $0.slug == resolved }) {
                            self.connections[idx].connected = true
                            self.connections[idx].viaComposio = true
                            self.connections[idx].accountLabel = "Signed in"
                        }
                        self.connectionSecrets[resolved] = ComposioClient.composioTokenSentinel
                        self.pluginError = nil
                        self.pluginAuthURL = nil
                    } else {
                        self.pluginError = ComposioClient.oauthFailedMessage(for: resolved)
                        if let guide = ComposioClient.setupGuideURL(for: resolved) {
                            self.presentPluginAuthURL(guide, setupHint: self.pluginError)
                        }
                    }
                }
            } catch {
                let message = error.localizedDescription
                if message.localizedCaseInsensitiveContains("already connected") {
                    if let idx = self.connections.firstIndex(where: { $0.slug == resolved }) {
                        self.connections[idx].connected = true
                        self.connections[idx].viaComposio = true
                        self.connections[idx].accountLabel = "Signed in"
                    }
                    self.connectionSecrets[resolved] = ComposioClient.composioTokenSentinel
                    self.pluginError = nil
                    self.pluginAuthURL = nil
                } else {
                    self.pluginError = message
                    if ComposioClient.requiresCustomAuthConfig(resolved),
                       let guide = ComposioClient.setupGuideURL(for: resolved) {
                        self.presentPluginAuthURL(guide, setupHint: message)
                    } else if let found = ComposioClient.firstAuthURL(in: message) {
                        self.presentPluginAuthURL(found, setupHint: message)
                    }
                }
            }
            self.connectionPending.remove(resolved)
            self.oauthWaitSlug = nil
            self.save()
            self.pluginTasks.removeValue(forKey: resolved)
        }
        pluginTasks[resolved] = task
    }

    public func revoke(slug: String) {
        guard !connectionPending.contains(slug) else { return }
        connectionPending.insert(slug)
        pluginTasks[slug]?.cancel()
        let token = connectionSecrets[slug]
        let viaComposio = connections.first(where: { $0.slug == slug })?.viaComposio == true
            || token == ComposioClient.composioTokenSentinel
        let viaGoogle = token == Self.googleTokenSentinel
            || (GoogleOAuth.isGooglePlugin(slug)
                && GoogleOAuth.decodeCredential(connectionSecrets[GoogleOAuth.credentialSecretKey]) != nil)
        let task = Task { [weak self] in
            guard let self else { return }
            if viaComposio, let composio = self.liveComposio() {
                try? await composio.disconnect(slug)
            } else if viaGoogle {
                // Keep shared Google credential if another Google plugin still uses it.
            } else if let token, token != ComposioClient.composioTokenSentinel, token != Self.googleTokenSentinel {
                await self.pluginClient.revoke(slug: slug, token: token)
            }
            if let idx = self.connections.firstIndex(where: { $0.slug == slug }) {
                self.connections[idx].connected = false
                self.connections[idx].accountLabel = nil
                self.connections[idx].viaComposio = false
            }
            self.connectionSecrets[slug] = nil
            let stillUsingGoogle = self.connections.contains {
                $0.connected && GoogleOAuth.isGooglePlugin($0.slug)
                    && self.connectionSecrets[$0.slug] == Self.googleTokenSentinel
            }
            if !stillUsingGoogle, let encoded = self.connectionSecrets[GoogleOAuth.credentialSecretKey],
               let cred = GoogleOAuth.decodeCredential(encoded),
               let google = self.liveGoogleOAuth() {
                await google.revoke(token: cred.refresh.isEmpty ? cred.access : cred.refresh)
                self.connectionSecrets[GoogleOAuth.credentialSecretKey] = nil
            }
            self.connectionPending.remove(slug)
            self.save()
            self.pluginTasks.removeValue(forKey: slug)
        }
        pluginTasks[slug] = task
    }

    public static let pluginAccountAll = "*"
    public static let pluginAccountKeySuffix = "#account"

    public static func pluginAccountKey(for slug: String) -> String {
        "\(slug)\(pluginAccountKeySuffix)"
    }

    /// `nil` = auto (first account), `*` = all accounts, otherwise a Composio account alias.
    public func pluginAccountPreference(for slug: String) -> String? {
        let raw = connectionSecrets[Self.pluginAccountKey(for: slug)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    public func setPluginAccountPreference(slug: String, account: String?) {
        let key = Self.pluginAccountKey(for: slug)
        let trimmed = account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            connectionSecrets[key] = nil
        } else {
            connectionSecrets[key] = trimmed
        }
        if trimmed != Self.pluginAccountAll,
           let idx = connections.firstIndex(where: { $0.slug == slug }),
           connections[idx].viaComposio {
            connections[idx].accountLabel = trimmed.isEmpty ? "Composio" : displayName(forPluginAccount: trimmed)
        }
        save()
    }

    func storeAccountPreferenceFromTool(slug: String, account: String) {
        let lower = account.lowercased()
        if lower == "all" || lower == "*" || lower == "every" || lower == "both" {
            setPluginAccountPreference(slug: slug, account: Self.pluginAccountAll)
        } else {
            setPluginAccountPreference(slug: slug, account: account)
        }
    }

    public func displayName(forPluginAccount account: String) -> String {
        if account == Self.pluginAccountAll { return "All accounts" }
        return account
            .replacingOccurrences(of: "gmail_", with: "")
            .replacingOccurrences(of: "googlecalendar_", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    public func refreshComposioAccountChoices(slug: String) async {
        guard let composio = liveComposio() else {
            composioAccountChoices[slug] = []
            return
        }
        composioAccountsLoadingSlug = slug
        defer { if composioAccountsLoadingSlug == slug { composioAccountsLoadingSlug = nil } }
        let found = (try? await composio.listAccounts(slug: slug)) ?? []
        if !found.isEmpty {
            composioAccountChoices[slug] = found
        }
        // Keep a previously chosen specific account if it disappeared.
        if let pref = pluginAccountPreference(for: slug),
           pref != Self.pluginAccountAll,
           !found.isEmpty,
           !found.contains(pref) {
            setPluginAccountPreference(slug: slug, account: nil)
        }
    }

    func writePlugin(slug: String, title: String, body: String, account: String? = nil) async throws -> String {
        let item = connections.first(where: { $0.slug == slug })
        let token = connectionSecrets[slug]
            ?? (slug == "box" ? appConfig.boxToken : nil)
        if let googleToken = try await liveGoogleAccessToken(for: slug) {
            return try await pluginClient.write(slug: slug, token: googleToken, title: title, body: body)
        }
        if item?.viaComposio == true || token == ComposioClient.composioTokenSentinel,
           let composio = liveComposio() {
            let pref = account ?? pluginAccountPreference(for: slug)
            if pref == Self.pluginAccountAll {
                let accounts = try await ensureComposioAccounts(slug: slug, composio: composio)
                guard !accounts.isEmpty else {
                    return try await composio.execute(slug: slug, title: title, body: body, account: nil)
                }
                var parts: [String] = []
                for name in accounts {
                    let remote = try await composio.execute(slug: slug, title: title, body: body, account: name)
                    parts.append("[\(displayName(forPluginAccount: name))]\n\(remote)")
                }
                return parts.joined(separator: "\n\n")
            }
            return try await composio.execute(slug: slug, title: title, body: body, account: pref)
        }
        guard let token, token != ComposioClient.composioTokenSentinel, token != Self.googleTokenSentinel else {
            throw PluginError.rejected("Plugin \(slug) is not connected.")
        }
        return try await pluginClient.write(slug: slug, token: token, title: title, body: body)
    }

    func deletePlugin(slug: String, id: String) async throws -> String {
        let token = connectionSecrets[slug]
        if let googleToken = try await liveGoogleAccessToken(for: slug) {
            return try await pluginClient.delete(slug: slug, token: googleToken, id: id)
        }
        guard let token, token != ComposioClient.composioTokenSentinel, token != Self.googleTokenSentinel else {
            throw PluginError.rejected("Plugin \(slug) is not connected.")
        }
        return try await pluginClient.delete(slug: slug, token: token, id: id)
    }

    func readPlugin(slug: String, query: String, account: String? = nil) async throws -> String {
        let item = connections.first(where: { $0.slug == slug })
        let token = connectionSecrets[slug]
            ?? (slug == "box" ? appConfig.boxToken : nil)
        if let googleToken = try await liveGoogleAccessToken(for: slug) {
            return try await pluginClient.search(slug: slug, token: googleToken, query: query)
        }
        if item?.viaComposio == true || token == ComposioClient.composioTokenSentinel,
           let composio = liveComposio() {
            let pref = account ?? pluginAccountPreference(for: slug)
            if pref == Self.pluginAccountAll {
                let accounts = try await ensureComposioAccounts(slug: slug, composio: composio)
                guard !accounts.isEmpty else {
                    return try await composio.search(slug: slug, query: query, account: nil)
                }
                var parts: [String] = []
                for name in accounts {
                    let remote = try await composio.search(slug: slug, query: query, account: name)
                    parts.append("## \(displayName(forPluginAccount: name))\n\(remote)")
                }
                return parts.joined(separator: "\n\n")
            }
            do {
                return try await composio.search(slug: slug, query: query, account: pref)
            } catch {
                // Cache account aliases from the error so the Plugins picker can populate.
                if let names = ComposioClient.multipleAccountChoices(in: error.localizedDescription) {
                    composioAccountChoices[slug] = names
                } else if error.localizedDescription.localizedCaseInsensitiveContains("Multiple accounts") {
                    await refreshComposioAccountChoices(slug: slug)
                }
                throw error
            }
        }
        guard let token, token != ComposioClient.composioTokenSentinel, token != Self.googleTokenSentinel else {
            throw PluginError.rejected("Plugin \(slug) is not connected.")
        }
        return try await pluginClient.search(slug: slug, token: token, query: query)
    }

    private func ensureComposioAccounts(slug: String, composio: any ComposioConnecting) async throws -> [String] {
        if let cached = composioAccountChoices[slug], !cached.isEmpty { return cached }
        let found = try await composio.listAccounts(slug: slug)
        if !found.isEmpty {
            composioAccountChoices[slug] = found
        }
        return found
    }

    func recordAudit(
        type: AuditEventType,
        botId: String?,
        tool: String?,
        reason: String,
        allowed: Bool?,
        forwarded: Bool?,
        matched: String? = nil,
        source: String? = nil,
        attributes: [String: JSONValue] = [:]
    ) {
        let event = AuditEvent(
            type: type,
            actorId: session?.userId ?? "local",
            botId: botId,
            tool: tool,
            matched: matched,
            source: source,
            allowed: allowed,
            forwarded: forwarded,
            reason: reason,
            attributes: attributes
        )
        auditEvents = AuditLog.appending(auditEvents, event)
    }

    func resolvePolicyElement(tool: String, argumentsJSON: String, botId: String) -> PolicyElement? {
        let args = JSONValue.parseObject(argumentsJSON)
        func num(_ keys: String...) -> Double? {
            for key in keys {
                if let value = JSONValue.object(args).stringValue(key), let n = Double(value) {
                    return n
                }
            }
            return nil
        }
        let computer = computers[botId]
        if tool == "computer_click" || tool == "computer_scroll" {
            let x = num("x") ?? 0
            let y = num("y") ?? 0
            return ComputerOutline.hit(outline: computer?.lastOutline ?? "", x: x, y: y)
        }
        if tool == "computer_key" {
            return computer?.lastElement
        }
        return nil
    }

    func recordBootBoundary() {
        let already = auditEvents.contains {
            $0.type == .computerPolicyLoaded && $0.actorId == (session?.userId ?? "local")
        }
        guard !already else { return }
        let deny = actionPolicy.deny.count
        let allow = actionPolicy.allow.count
        recordAudit(
            type: .computerPolicyLoaded,
            botId: nil,
            tool: nil,
            reason: "Policy \(actionPolicy.mode.rawValue) loaded. Deny \(deny), allow \(allow).",
            allowed: true,
            forwarded: true,
            attributes: [
                "mode": .string(actionPolicy.mode.rawValue),
                "deny": .number(Double(deny)),
                "allow": .number(Double(allow)),
            ]
        )
        let host = deployment.normalizedHost?.rawValue ?? deployment.computerHost ?? "none"
        recordAudit(
            type: .computerIsolationLoaded,
            botId: nil,
            tool: nil,
            reason: "Computer boundary: \(host). This Mac vs in-app browser; not a cloud VM.",
            allowed: true,
            forwarded: true,
            attributes: ["boundary": .string(host)]
        )
        globalPersistence.saveAudit(auditEvents)
    }

    func syncPluginKnowledge(query: String, botId: String) async {
        let visible = KnowledgePlane.sourcesVisible(to: botId, from: knowledgeSources)
        for source in visible where source.kind == .plugin {
            do {
                let text = try await readPlugin(slug: source.path, query: query)
                let docs = KnowledgePlane.documents(from: text, source: source)
                memory.removeAll { $0.scope == "knowledge" && $0.botId == source.id }
                memory.append(contentsOf: docs)
                recordAudit(
                    type: .connectorSyncSucceeded,
                    botId: botId,
                    tool: "search_knowledge",
                    reason: "Synced \(source.path) (\(docs.count) docs).",
                    allowed: true,
                    forwarded: true,
                    attributes: ["source": .string(source.path)]
                )
            } catch {
                recordAudit(
                    type: .connectorSyncFailed,
                    botId: botId,
                    tool: "search_knowledge",
                    reason: "Sync \(source.path) failed: \(error.localizedDescription)",
                    allowed: false,
                    forwarded: false,
                    attributes: ["source": .string(source.path)]
                )
            }
        }
    }

    func knowledgeDocuments() -> [MemoryDocument] {
        var docs: [MemoryDocument] = []
        for source in knowledgeSources {
            switch source.kind {
            case .folder:
                docs.append(contentsOf: KnowledgePlane.indexFolder(source: source))
            case .plugin:
                docs.append(contentsOf: memory.filter { $0.scope == "knowledge" && $0.botId == source.id })
            }
        }
        return docs
    }

    public func setStallTimeout(_ ms: Int) {
        guard isOwner else { return }
        appConfig.agentStallTimeoutMs = max(0, ms)
        save()
    }

    public func setActionPolicy(_ policy: ActionPolicy) {
        guard isOwner else { return }
        actionPolicy = policy
        recordAudit(
            type: .configurationChanged,
            botId: nil,
            tool: nil,
            reason: "Action policy updated (\(policy.mode.rawValue)).",
            allowed: true,
            forwarded: true,
            attributes: [
                "deny": .number(Double(policy.deny.count)),
                "allow": .number(Double(policy.allow.count)),
            ]
        )
        save()
    }

    public func addKnowledgeSource(_ source: KnowledgeSource) {
        guard isOwner else { return }
        knowledgeSources.append(source)
        save()
    }

    public func removeKnowledgeSource(_ id: String) {
        guard isOwner else { return }
        knowledgeSources.removeAll { $0.id == id }
        memory.removeAll { $0.scope == "knowledge" && $0.botId == id }
        save()
    }

    public func setPluginGranted(botId: String, plugin: String, tool: String? = nil, granted: Bool) {
        guard isOwner else { return }
        let family = PluginGrant.family(of: plugin)
        let familyEmpty = pluginGrants.filter { $0.botId == botId && PluginGrant.family(of: $0.plugin) == family }.isEmpty
        if familyEmpty, !granted, tool == nil, family == "mcp" {
            for server in mcpServers where server.toolId != plugin {
                pluginGrants.append(PluginGrant(botId: botId, plugin: server.toolId))
            }
        } else {
            if tool == nil {
                pluginGrants.removeAll { $0.botId == botId && $0.plugin == plugin }
            } else {
                pluginGrants.removeAll { $0.botId == botId && $0.plugin == plugin && $0.tool == tool }
            }
            if granted {
                pluginGrants.append(PluginGrant(botId: botId, plugin: plugin, tool: tool))
            }
        }
        recordAudit(
            type: .configurationChanged,
            botId: botId,
            tool: nil,
            reason: granted ? "Granted \(plugin)." : "Revoked \(plugin).",
            allowed: true,
            forwarded: true
        )
        save()
    }

    public func isPluginGranted(botId: String, plugin: String, tool: String? = nil) -> Bool {
        PluginGrant.allows(grants: pluginGrants, botId: botId, plugin: plugin, tool: tool)
    }

    public func saveSandboxComponent(_ component: SandboxComponent) {
        guard isOwner else { return }
        if let idx = sandboxComponents.firstIndex(where: { $0.id == component.id }) {
            sandboxComponents[idx] = component
        } else {
            sandboxComponents.append(component)
        }
        save()
    }

    public func publishSandboxComponent(_ id: String, published: Bool) {
        guard isOwner else { return }
        guard let idx = sandboxComponents.firstIndex(where: { $0.id == id }) else { return }
        sandboxComponents[idx].published = published
        save()
    }

    public func removeSandboxComponent(_ id: String) {
        guard isOwner else { return }
        sandboxComponents.removeAll { $0.id == id }
        save()
    }

    public func setBotComponent(_ botId: String, componentId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        var list = bots[idx].enabledComponents
        if enabled {
            if !list.contains(componentId) { list.append(componentId) }
        } else {
            list.removeAll { $0 == componentId }
        }
        bots[idx].enabledComponents = list
        bots[idx].updatedAt = .now
        save()
    }

    public func recordSecretEvent(requested: Bool, label: String, characterCount: Int, botId: String?) {
        recordAudit(
            type: requested ? .computerSecretRequested : .computerSecretSupplied,
            botId: botId,
            tool: nil,
            reason: requested ? "Secret requested." : "Secret supplied.",
            allowed: true,
            forwarded: true,
            attributes: AuditRedactor.secretRecord(label: label, characterCount: characterCount)
        )
        save()
    }

    func gatedWrite(
        tool: String,
        detail: String,
        argumentsJSON: String,
        bot: Bot,
        approved: Bool
    ) -> AgentToolCallResult? {
        if approved || bot.autoApprove || bot.alwaysAllowTools.contains(tool) { return nil }
        return AgentToolCallResult(
            output: "Need approval to run \(tool): \(detail)",
            blocks: [.approval(tool: tool, detail: detail, status: .pending)],
            pause: .approval(tool: tool, detail: detail, arguments: argumentsJSON)
        )
    }

    static func approvalFunctionName(_ tool: String) -> String {
        switch tool {
        case "shell.exec": return "shell"
        case "read_file.host": return "read_file"
        case "list_files.host": return "list_files"
        case "write_file.host": return "write_file"
        case "edit_file.host": return "edit_file"
        case "move_file.host": return "move_file"
        case "delete_file.host": return "delete_file"
        default:
            // Per-tool approvals are keyed `mcp_call:<server>/<tool>` but run as `mcp_call`.
            return tool.hasPrefix("mcp_call:") ? "mcp_call" : tool
        }
    }

    private func resolvedComputerMode(for bot: Bot) -> ComputerMode {
        if bot.computerMode != .auto { return bot.computerMode }
        if appConfig.defaultComputerMode != .auto { return appConfig.defaultComputerMode }
        return deployment.normalizedHost == .thisMac ? .thisMac : .inAppBrowser
    }

    /// UI: This Mac is preview-only (screenshot poll); drive happens on the real desktop.
    public func isThisMacComputer(botId: String) -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        return resolvedComputerMode(for: bot) == .thisMac
    }

    func computerBlockedIfHeadless(bot: Bot) -> AgentToolCallResult? {
        guard headlessRoutineTick else { return nil }
        guard resolvedComputerMode(for: bot) == .thisMac else { return nil }
        return AgentToolCallResult(
            output: "This Mac computer is unavailable during a background routine tick. Screen Recording and Accessibility need GrizzyBot in the foreground. Open the app to run computer tools, or switch this bot to In-app browser."
        )
    }

    /// Applies computer mode to the runtime and attaches the bot home before screen I/O.
    @discardableResult
    func prepareComputerSurface(botId: String, bot: Bot) async -> URL {
        let home = (try? botHome.homeURL(botId: botId)) ?? userPersistence.root
        let mode = resolvedComputerMode(for: bot)
        await computerRuntime?.setSession(
            botId: botId,
            thisMac: mode == .thisMac,
            persistent: mode != .off
        )
        await computerRuntime?.attach(botId: botId, homeURL: home)
        if var computer = computers[botId], computer.state != .running {
            computer.state = .running
            computer.screenAvailable = true
            computers[botId] = computer
        }
        return home
    }

    /// The other bots this bot should know about. Without this the prompt says
    /// nothing about siblings and a bot resorts to shelling around the app
    /// support folder to discover them.
    public func rosterEntries(for bot: Bot) -> [BotRosterEntry] {
        bots
            .filter { $0.id != bot.id && !$0.hidden }
            .map {
                BotRosterEntry(
                    name: $0.name,
                    title: $0.title.isEmpty ? $0.description : $0.title,
                    isChild: $0.parentBotId == bot.id,
                    isChiefOfStaff: $0.chiefOfStaff
                )
            }
    }

    func computerNote(for bot: Bot) -> String {
        let mode = resolvedComputerMode(for: bot)
        switch mode {
        case .thisMac:
            return "This Mac desktop via Accessibility. Needs Screen Recording and Accessibility permission. Not a cloud VM."
        case .off:
            return "Computer is off for this bot."
        case .inAppBrowser:
            return "Persistent in-app browser for this bot. Cookies survive relaunch."
        default:
            return "Follows workspace default computer mode."
        }
    }

    func appendLiveTool(threadKey: String, runId: String, name: String, result: AgentToolCallResult) {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        var blocks = result.blocks
        if blocks.isEmpty {
            let preview: String
            if name == "plugin_call" {
                preview = ComposioClient.chatSummary(
                    slug: "plugin",
                    query: "",
                    result: result.output,
                    failed: result.output.localizedCaseInsensitiveContains("failed")
                )
            } else {
                preview = String(result.output.prefix(120))
            }
            blocks = [.card(lines: [CardLine(k: name, v: preview)])]
        }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        threads[threadKey] = thread
    }

    public func startRoutineScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await MainActor.run { self?.tickDueRoutines() }
            }
        }
    }

    public func tickDueRoutines() {
        let now = Date.now
        recoverStuckRoutines(now: now)
        var activeRoutineRuns = 0
        for (botId, _) in routines {
            let run = threads[threadKey(for: botId)]?.run
            if run?.status.isActive == true, RoutineTrigger.isRoutine(run?.trigger ?? "") {
                activeRoutineRuns += 1
            }
        }
        var due: [(botId: String, routine: Routine)] = []
        for (botId, list) in routines {
            let key = threadKey(for: botId)
            if let status = threads[key]?.run?.status {
                switch status {
                case .running, .queued, .leased, .waitingInput, .waitingTakeover:
                    continue
                case .completed, .failed, .cancelled:
                    break
                }
            }
            guard let routine = list.first(where: { item in
                item.active && !item.inProgress && (item.nextRunAt.map { $0 <= now } ?? false)
            }) else { continue }
            due.append((botId, routine))
        }
        let slots = RoutineTickPolicy.admit(dueCount: due.count, activeRoutineRuns: activeRoutineRuns)
        for item in due.prefix(slots) {
            fireRoutine(botId: item.botId, routine: item.routine)
        }
    }

    private func recoverStuckRoutines(now: Date) {
        let stale: TimeInterval = 30 * 60
        for (botId, list) in routines {
            let key = threadKey(for: botId)
            let run = threads[key]?.run
            let runBusy: Bool = {
                guard let status = run?.status else { return false }
                switch status {
                case .running, .queued, .leased, .waitingInput, .waitingTakeover:
                    return true
                default:
                    return false
                }
            }()
            for (idx, routine) in list.enumerated() where routine.inProgress {
                let last = routine.lastRunAt ?? .distantPast
                if runBusy, run?.routineId == routine.id { continue }
                if now.timeIntervalSince(last) < stale { continue }
                let fails = routine.failCount + 1
                routines[botId]?[idx].inProgress = false
                routines[botId]?[idx].failCount = fails
                routines[botId]?[idx].lastError = "stale in-progress run"
                routines[botId]?[idx].nextRunAt = fails <= Cron.retryLimit
                    ? Cron.backoffDate(failCount: fails, from: now)
                    : Cron.nextDate(routine.cron, from: now, timezone: routine.timezone)
            }
        }
    }
}
