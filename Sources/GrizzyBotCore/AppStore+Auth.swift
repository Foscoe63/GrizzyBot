import Foundation
import Observation

// Local account and sign-in.
extension AppStore {
    // MARK: - Auth

    public func goToSignIn(email: String = "") {
        if !email.isEmpty { pendingAuthEmail = email }
        route = .signIn
    }
    public func goToSignUp() { route = .signUp }
    public func goToWelcome() { route = .welcome }

    public func signUp(name: String, email: String, password: String) -> String? {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            return "Invalid email address"
        }
        guard password.count >= 8 else {
            return "Password must be at least 8 characters"
        }
        if users.contains(where: { $0.email.lowercased() == trimmedEmail }) {
            return "An account with this email already exists."
        }
        let local = trimmedEmail.split(separator: "@").first.map(String.init) ?? "User"
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = resolvedName.isEmpty ? (local.isEmpty ? "User" : local) : resolvedName
        if isOwner {
            saveGovernanceIfOwner()
        }
        let role: AccountRole = users.contains(where: { $0.role == .owner }) ? .operatorUser : .owner
        let userId = Ids.new()
        try? AccountCredentialStore.save(userId: userId, passwordHash: PasswordHasher.hash(password))
        let user = UserAccount(
            id: userId,
            email: trimmedEmail,
            name: finalName,
            role: role
        )
        users.append(user)
        attachUserPersistence(userId: userId)
        session = Session(userId: user.id, name: user.name, email: user.email)
        bots = []
        threads = [:]
        routines = [:]
        computers = [:]
        connections = ConnectionCatalog.defaults
        usage = []
        memory = []
        files = []
        deployment = DeploymentSettings()
        modelProvider = nil
        modelId = nil
        apiKey = nil
        modelBaseUrl = nil
        fetchedModels = []
        activeBotId = nil
        applyGovernance(globalPersistence.loadGovernance() ?? currentGovernance())
        route = .onboarding
        save()
        recordBootBoundary()
        return nil
    }

    public func signIn(email: String, password: String) -> String? {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let user = users.first(where: { $0.email.lowercased() == trimmedEmail }),
              AccountCredentialStore.verify(userId: user.id, password: password)
        else {
            return "Invalid login credentials"
        }
        if let stored = AccountCredentialStore.load(userId: user.id),
           PasswordHasher.needsUpgrade(stored) {
            try? AccountCredentialStore.save(userId: user.id, passwordHash: PasswordHasher.hash(password))
        }
        if session?.userId != user.id {
            save()
        }
        session = Session(userId: user.id, name: user.name, email: user.email)
        attachUserPersistence(userId: user.id)
        loadWorkspace(for: user.id)
        route = bots.isEmpty ? .onboarding : .shell
        if route == .shell, deployment.computerHost == nil {
            showHostPrompt = true
        }
        save()
        return nil
    }

    public func signOut() {
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        for (_, task) in delegateTimers { task.cancel() }
        delegateTimers.removeAll()
        for (_, task) in bootTasks { task.cancel() }
        bootTasks.removeAll()
        panel = nil
        computerOpen = false
        canvasOpen = false
        booting = false
        pluginsOpen = false
        showHostPrompt = false
        save()
        session = nil
        globalPersistence.saveSession(nil)
        clearWorkspaceState()
        route = .welcome
    }

    public func saveModelSelection(
        provider: String,
        modelId: String,
        apiKey: String?,
        baseUrl: String? = nil,
        models: [LocalModelRef] = []
    ) {
        updateModelProviderDraft(
            provider: provider,
            modelId: modelId,
            apiKey: apiKey,
            baseUrl: baseUrl,
            models: models
        )
        var profile = providerProfiles[provider] ?? ModelProviderProfile()
        if let baseUrl, !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.baseUrl = (try? LocalProviders.normalizeBaseUrl(baseUrl, provider: provider)) ?? baseUrl
        } else if LocalProviders.isLocal(provider) {
            profile.baseUrl = LocalProviders.def(for: provider)?.defaultBaseUrl
        } else if !ModelCatalog.usesCustomBase(provider) {
            profile.baseUrl = nil
        }
        profile.enabled = true
        providerProfiles[provider] = profile
        self.modelProvider = provider
        syncActiveProviderFields()
        save()
    }

    public func saveOAuthCredential(_ credential: OAuthCredential, provider: String, modelId: String) {
        var cred = providerCredentials[provider] ?? ProviderCredential()
        if let data = try? JSONEncoder().encode(credential), let json = String(data: data, encoding: .utf8) {
            cred.oauthJSON = json
        }
        cred.apiKey = credential.access
        providerCredentials[provider] = cred

        var profile = providerProfiles[provider] ?? ModelProviderProfile()
        profile.modelId = modelId
        profile.enabled = true
        providerProfiles[provider] = profile

        self.modelProvider = provider
        syncActiveProviderFields()
        save()
    }

    public func openModelSettings() {
        modelSettingsOpen = true
    }

    public func closeModelSettings() {
        modelSettingsOpen = false
    }

    public func finishOnboarding(
        name: String,
        title: String,
        description: String,
        answers: [String]
    ) {
        let instructions: String
        if answers.isEmpty {
            instructions = description
        } else {
            instructions = "User setup:\n" + answers.map { "- \($0)" }.joined(separator: "\n")
        }
        let bot = createBot(
            name: name,
            title: title,
            description: description,
            instructions: instructions,
            parentBotId: nil
        )
        if var updated = bots.first(where: { $0.id == bot.id }) {
            updated.notifyOnFinish = true
            if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
                bots[idx] = updated
            }
        }
        activeBotId = bot.id
        route = .shell
        if deployment.computerHost == nil {
            showHostPrompt = true
        }
        save()
    }
}
