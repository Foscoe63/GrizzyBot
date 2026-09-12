import Foundation
import Observation

/// App routing, mirroring rakazo Shell auth redirects.
public enum Route: Sendable, Equatable {
    case welcome
    case signIn
    case signUp
    case onboarding
    case shell
}

/// Which right-side panel is open in the shell.
public enum Panel: String, Sendable, Equatable {
    case computer
    case create
    case settings
    case routine
    case canvas
    case artifact
}

/// Heart of the app: local store mirroring rakazo Shell.tsx state + API behavior.
@MainActor
@Observable
public final class AppStore {
    public var route: Route = .welcome
    public var session: Session?
    public var bots: [Bot] = []
    public var folderWatchers: [FolderWatcherRecord] = []
    public var activeBotId: String?
    public var threads: [String: ThreadData] = [:]
    public var routines: [String: [Routine]] = [:]
    public var computers: [String: ComputerStatus] = [:]
    public var connections: [ConnectionItem] = ConnectionCatalog.defaults
    public var usage: [UsageRecord] = []
    public var memory: [MemoryDocument] = []
    public var files: [[String]] = []
    public var deployment: DeploymentSettings = DeploymentSettings()
    public var modelProvider: String?
    public var modelId: String?
    public var apiKey: String?
    public var modelBaseUrl: String?
    public var fetchedModels: [LocalModelRef] = []
    public var providerProfiles: [String: ModelProviderProfile] = [:]
    public var modelSettingsOpen: Bool = false
    public var groups: [GroupRoom] = []
    public var appConfig: AppConfig = AppConfig()
    public var customTools: [CustomAgentTool] = []
    public var mcpServers: [McpServer] = []
    public var actionPolicy: ActionPolicy = .openDefault
    public var knowledgeSources: [KnowledgeSource] = []
    public var pluginGrants: [PluginGrant] = []
    public var sandboxComponents: [SandboxComponent] = []
    public var mcpAdvertisedTools: [String: [String]] = [:]
    /// Session cache of Toolport/MacUse catalog tools promoted to first-class ChatTools.
    public var mcpPromotedTools: [String: McpPromotedTool] = [:]
    /// Live MCP connection probes (not persisted).
    public var mcpProbeStatus: [String: McpProbeStatus] = [:]
    /// Last successful `tools/list` payloads for UI subtitles (not persisted).
    public var mcpListedTools: [String: [McpToolInfo]] = [:]
    private var mcpProbeGeneration: [String: UInt64] = [:]
    public var auditEvents: [AuditEvent] = []
    public var appSettingsOpen: Bool = false
    public var appSettingsSection: AppSettingsSection = .general
    public var mainView: ShellMainView = .chat
    public var activeGroupId: String?
    public var composerDrafts: [String: String] = [:]
    public var runLog: [RunLogLine] = []
    public var chatSearchOpen: Bool = false
    public var highlightMessageId: String?
    public var pendingComposerText: String?
    /// Prefills Sign in when the user picks an existing account on Welcome.
    public var pendingAuthEmail: String = ""

    public enum AppSettingsSection: String, Sendable, CaseIterable, Identifiable {
        case general, connections, computer, voice, tools, themes, privacy, watchers, diagnostics, governance, knowledge, components
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .general: return "General"
            case .connections: return "Connections"
            case .computer: return "Computer"
            case .voice: return "Voice"
            case .tools: return "Tools"
            case .themes: return "Themes"
            case .privacy: return "Privacy"
            case .watchers: return "Watchers"
            case .diagnostics: return "Diagnostics"
            case .governance: return "Governance"
            case .knowledge: return "Knowledge"
            case .components: return "Components"
            }
        }
    }

    public var panel: Panel? = nil
    public var computerOpen: Bool = false
    public var canvasOpen: Bool = false
    public var activeCanvasId: String?
    public var canvases: [CanvasRecord] = []
    public var canvasRevision: Int = 0
    public var artifacts: [ArtifactRecord] = []
    public var activeArtifactId: String?
    /// Bumped on every artifact write so the panel's web frame reloads.
    public var artifactRevision: Int = 0
    /// Which saved version the panel is showing; nil means the current one.
    public var artifactVersionIndex: Int?
    public var booting: Bool = false
    public var pluginsOpen: Bool = false
    public var skillsOpen: Bool = false
    public var skills: [AgentSkill] = []
    public var showHostPrompt: Bool = false
    /// App layer: speak replies and local notifications.
    public var onRunFinished: ((Bot, String) -> Void)?
    public var editingRoutineId: String? = nil
    public var routineDraft: RoutineDraft = RoutineDraft()

    public var connectionPending: Set<String> = []

    public var pluginsUseOAuth: Bool {
        composioClient != nil || appConfig.composioConfigured
    }

    public var googlePluginsReady: Bool {
        googleOAuthClient != nil || appConfig.googleOAuthConfigured
    }

    private func liveComposio() -> (any ComposioConnecting)? {
        if let composioClient { return composioClient }
        let key = (appConfig.composioConnectKey ?? appConfig.composioApiKey ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return ComposioClient(connectKey: key, apiKey: appConfig.composioApiKey)
    }

    private func liveGoogleOAuth() -> (any GoogleOAuthConnecting)? {
        if let googleOAuthClient { return googleOAuthClient }
        guard appConfig.googleOAuthConfigured else { return nil }
        return GoogleOAuthClient(openURL: { [weak self] url in
            Task { @MainActor in
                self?.presentPluginAuthURL(url)
            }
        })
    }

    /// Open a Composio/Google sign-in URL in the system browser and keep it visible in the Plugins UI.
    public func presentPluginAuthURL(_ url: URL, setupHint: String? = nil) {
        let openable = Self.browserOpenableURL(url) ?? url
        pluginAuthURL = openable
        if let setupHint {
            pluginError = setupHint
        } else if ComposioClient.isAuthConfigSetupURL(url) || ComposioClient.isAuthConfigSetupURL(openable) {
            pluginError = ComposioClient.authSetupMessage(for: "x", url: openable)
        }
        // Defer past the current SwiftUI transaction — opening a browser mid-body update crashes.
        let open = openExternalURL
        DispatchQueue.main.async {
            open?(openable)
        }
    }

    public func reopenPluginAuthURL() {
        guard let url = pluginAuthURL else { return }
        let open = openExternalURL
        DispatchQueue.main.async {
            open?(url)
        }
    }

    /// Prefer http(s). Bare Composio API/auth-apps links often show “could not open app” in the browser.
    private static func browserOpenableURL(_ url: URL) -> URL? {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        if ComposioClient.isAuthConfigSetupURL(url) {
            return URL(string: "https://app.composio.dev")
        }
        return url
    }

    /// Resolve catalog aliases (`twitter` ↔ `x`) so plugin_call and Connect share one connection.
    public func resolvePluginSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return trimmed }
        if connections.contains(where: { $0.slug == trimmed }) { return trimmed }
        let key = ComposioClient.toolkitSlug(trimmed)
        if let match = connections.first(where: { ComposioClient.toolkitSlug($0.slug) == key }) {
            return match.slug
        }
        return trimmed
    }

    private var users: [UserAccount] = []
    private let globalRoot: URL
    private var globalPersistence: Persistence
    private var userPersistence: Persistence
    private var botHome: BotHomeStore
    private var destinations: DestinationStore
    private var canvasBoard: CanvasBoardStore
    private var artifactStore: ArtifactStore
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var bootTasks: [String: Task<Void, Never>] = [:]
    private var pluginTasks: [String: Task<Void, Never>] = [:]
    private var schedulerTask: Task<Void, Never>?

    /// Shorter delays in tests so `swift test` stays fast.
    public var delayScale: Double = 1.0
    /// Watcher runs pin file tools to the watch path until the run goes idle.
    private var runWorkingFolderOverride: [String: String] = [:]
    /// Bot currently executing a watcher-triggered run (for echo suppression).
    private var watcherRunByBotId: [String: String] = [:]
    /// Injected chat client (tests). Production picks one per provider — see
    /// `defaultClient(for:)`.
    public var chatCompleter: (any ChatCompleting)?

    /// The client that serves `provider`. Everything speaks HTTP to an
    /// OpenAI-compatible (or Anthropic) endpoint except Local MLX, which runs
    /// the model in this process.
    static func defaultClient(for provider: String?) -> any ChatCompleting {
        MLXProvider.isMLX(provider) ? MLXChatClient.shared : OpenAIChatClient.shared
    }
    public var oauthJSON: String?
    private var providerCredentials: [String: ProviderCredential] = [:]
    public var connectionSecrets: [String: String] = [:]
    public var computerRuntime: (any ComputerRuntime)?
    public var pluginClient: any PluginConnecting = PluginClient.shared
    public var composioClient: (any ComposioConnecting)?
    public var googleOAuthClient: (any GoogleOAuthConnecting)?
    /// App layer opens OAuth / Composio URLs (NSWorkspace). Must not be observed — storing a
    /// closure on an `@Observable` property crashes PluginsOverlayView body updates (SIGBUS).
    @ObservationIgnored
    public var openExternalURL: ((URL) -> Void)?
    public var pluginError: String?
    public var connectingSlug: String?
    public var pluginAuthURL: URL?
    public var oauthWaitSlug: String?
    public var composioCatalog: [ConnectionItem] = []
    public var composioCatalogLoading = false
    public var composioCatalogError: String?
    /// Discovered Composio account aliases per plugin slug (e.g. gmail → [gmail_a, gmail_b]).
    public var composioAccountChoices: [String: [String]] = [:]
    public var composioAccountsLoadingSlug: String?

    public struct RoutineDraft: Sendable, Equatable {
        public var name: String = ""
        public var prompt: String = ""
        public var preset: Cron.Preset = Cron.defaultPreset()
        /// Bot that will own / run this routine (OpenMausBot "Who does it?").
        public var botId: String = ""

        public init(
            name: String = "",
            prompt: String = "",
            preset: Cron.Preset = Cron.defaultPreset(),
            botId: String = ""
        ) {
            self.name = name
            self.prompt = prompt
            self.preset = preset
            self.botId = botId
        }
    }

    public init(dataDirectory: URL? = nil, delayScale: Double = 1.0) {
        let root = dataDirectory ?? Persistence.defaultGlobalRoot()
        self.globalRoot = root
        AccountMigration.migrateIfNeeded(globalRoot: root)
        self.globalPersistence = Persistence(root: root)
        self.userPersistence = Persistence(root: root)
        self.botHome = BotHomeStore(root: root)
        self.destinations = DestinationStore(root: root)
        self.canvasBoard = CanvasBoardStore(root: root)
        self.artifactStore = ArtifactStore(root: root)
        self.computerRuntime = FileDesktopRuntime()
        self.delayScale = delayScale
        bootstrap()
        reloadSkills()
        reloadCanvases()
        seedSeenToolIdsIfNeeded()
        var catalogChanged = false
        for id in AgentToolCatalog.builtinIds + CanvasBoardStore.toolIds + ArtifactStore.toolIds {
            if optInNewTool(id) { catalogChanged = true }
        }
        if catalogChanged {
            save()
        }
        if delayScale >= 1 {
            startRoutineScheduler()
        }
    }

    // MARK: - Bootstrap

    /// Stable local account — no sign-in required at launch.
    private static let localEmail = "local@grizzybot.local"
    private static let localName = "Local User"

    private func bootstrap() {
        users = globalPersistence.loadUsers()
        if let session = globalPersistence.loadSession(),
           users.contains(where: { $0.id == session.userId }) {
            enterSession(session)
        } else if users.isEmpty {
            ensureLocalSession()
        } else {
            route = .welcome
        }
    }

    /// Creates or reuses the on-device user and routes straight into onboarding/shell.
    private func ensureLocalSession() {
        let user: UserAccount
        if let existing = users.first(where: { $0.email == Self.localEmail }) {
            user = existing
        } else {
            let userId = Ids.new()
            try? AccountCredentialStore.save(userId: userId, passwordHash: PasswordHasher.hash(Ids.new()))
            user = UserAccount(
                id: userId,
                email: Self.localEmail,
                name: Self.localName
            )
            users.append(user)
            globalPersistence.saveUsers(users)
        }
        enterSession(Session(userId: user.id, name: user.name, email: user.email))
    }

    /// Resume the built-in local workspace from the welcome screen.
    public func continueAsLocalUser() {
        ensureLocalSession()
    }

    /// Registered accounts on this Mac (passwords live in Keychain).
    public var registeredAccounts: [UserAccount] { users }

    public var currentRole: AccountRole {
        guard let id = session?.userId else { return .operatorUser }
        return users.first(where: { $0.id == id })?.role ?? .operatorUser
    }

    public var isOwner: Bool { currentRole == .owner }

    private func attachUserPersistence(userId: String) {
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        userPersistence = Persistence(root: userDir)
        botHome = BotHomeStore(root: userDir)
        destinations = DestinationStore(root: userDir)
    }

    private func enterSession(_ session: Session) {
        attachUserPersistence(userId: session.userId)
        self.session = session
        loadWorkspace(for: session.userId)
        reloadFolderWatchers()
        route = bots.isEmpty ? .onboarding : .shell
        showHostPrompt = route == .shell && deployment.computerHost == nil
        globalPersistence.saveSession(session)
        recordBootBoundary()
        refreshLocalIntegrations()
    }

    private func loadWorkspace(for userId: String) {
        applyWorkspace(userPersistence.loadWorkspace(userId: userId))
    }

    private func clearWorkspaceState() {
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
        providerProfiles = [:]
        providerCredentials = [:]
        groups = []
        customTools = []
        mcpServers = []
        folderWatchers = []
        actionPolicy = .openDefault
        knowledgeSources = []
        pluginGrants = []
        sandboxComponents = []
        mcpAdvertisedTools = [:]
        mcpPromotedTools = [:]
        mcpProbeStatus = [:]
        mcpListedTools = [:]
        mcpProbeGeneration = [:]
        auditEvents = []
        oauthJSON = nil
        connectionSecrets = [:]
        activeBotId = nil
        activeGroupId = nil
        panel = nil
        computerOpen = false
        canvasOpen = false
        booting = false
        pluginsOpen = false
        showHostPrompt = false
        mainView = .chat
    }

    private func applyWorkspace(_ ws: UserWorkspace) {
        bots = ws.bots
        threads = ws.threads
        routines = ws.routines
        computers = ws.computers
        connections = ws.connections.isEmpty ? ConnectionCatalog.defaults : ws.connections
        usage = ws.usage
        memory = ws.memory
        files = ws.files
        deployment = ws.deployment
        modelProvider = ws.modelProvider
        modelId = ws.modelId
        apiKey = ws.apiKey
        modelBaseUrl = ws.modelBaseUrl
        fetchedModels = ws.fetchedModels
        providerProfiles = ModelProviderProfiles.migrateProfiles(from: ws)
        groups = ws.groups
        appConfig = ws.appConfig
        customTools = ws.customTools
        mcpServers = ws.mcpServers.map { server in
            var copy = server
            copy.args = FastFilesystemMcpArgs.normalize(command: copy.command, args: copy.args)
            return copy
        }
        actionPolicy = ws.actionPolicy
        knowledgeSources = ws.knowledgeSources
        pluginGrants = ws.pluginGrants
        sandboxComponents = ws.sandboxComponents
        mcpAdvertisedTools = ws.mcpAdvertisedTools
        auditEvents = globalPersistence.loadAudit()
        if auditEvents.isEmpty {
            auditEvents = userPersistence.loadAudit()
        }
        applyGovernance(globalPersistence.loadGovernance() ?? GovernanceBundle(
            actionPolicy: ws.actionPolicy,
            pluginGrants: ws.pluginGrants,
            knowledgeSources: ws.knowledgeSources,
            sandboxComponents: ws.sandboxComponents,
            mcpAdvertisedTools: ws.mcpAdvertisedTools
        ))
        oauthJSON = ws.oauthJSON
        connectionSecrets = ws.connectionSecrets
        if let userId = session?.userId, let secrets = SecretStore.load(userId: userId) {
            providerCredentials = ModelProviderProfiles.migrateCredentials(
                from: ws,
                existing: secrets.providerCredentials
            )
            for (provider, cred) in secrets.providerCredentials where !cred.isEmpty {
                providerCredentials[provider] = cred
            }
        } else {
            providerCredentials = ModelProviderProfiles.migrateCredentials(from: ws, existing: [:])
        }
        syncActiveProviderFields()
        mergeCatalog(ConnectionCatalog.defaults)
        applyBoxToken(appConfig.boxToken, persist: false)
        if !appConfig.profileName.isEmpty, let existing = session {
            var updated = existing
            updated.name = appConfig.profileName
            if !appConfig.profileEmail.isEmpty { updated.email = appConfig.profileEmail }
            session = updated
        }
        activeBotId = bots.first(where: { !$0.hidden })?.id ?? bots.first?.id
        activeGroupId = nil
        panel = nil
        computerOpen = false
        canvasOpen = false
        booting = false
        pluginsOpen = false
        skillsOpen = false
        mainView = .chat
        hydrateMemoryFiles()
        seedSeenToolIdsIfNeeded()
    }

    private func currentWorkspace() -> UserWorkspace {
        UserWorkspace(
            bots: bots,
            threads: threads,
            routines: routines,
            computers: computers,
            connections: connections,
            usage: usage,
            memory: memory,
            files: files,
            deployment: deployment,
            modelProvider: modelProvider,
            modelId: modelId,
            apiKey: apiKey,
            modelBaseUrl: modelBaseUrl,
            fetchedModels: fetchedModels,
            providerProfiles: providerProfiles,
            groups: groups,
            appConfig: appConfig,
            customTools: customTools,
            mcpServers: mcpServers,
            oauthJSON: oauthJSON,
            connectionSecrets: connectionSecrets,
            actionPolicy: actionPolicy,
            knowledgeSources: knowledgeSources,
            pluginGrants: pluginGrants,
            sandboxComponents: sandboxComponents,
            mcpAdvertisedTools: mcpAdvertisedTools
        )
    }

    private func currentGovernance() -> GovernanceBundle {
        GovernanceBundle(
            actionPolicy: actionPolicy,
            pluginGrants: pluginGrants,
            knowledgeSources: knowledgeSources,
            sandboxComponents: sandboxComponents,
            mcpAdvertisedTools: mcpAdvertisedTools
        )
    }

    private func applyGovernance(_ bundle: GovernanceBundle) {
        actionPolicy = bundle.actionPolicy
        pluginGrants = bundle.pluginGrants
        knowledgeSources = bundle.knowledgeSources
        sandboxComponents = bundle.sandboxComponents
        mcpAdvertisedTools = bundle.mcpAdvertisedTools
    }

    private func saveGovernanceIfOwner() {
        guard isOwner else { return }
        globalPersistence.saveGovernance(currentGovernance())
    }

    private func save() {
        guard let userId = session?.userId else { return }
        persistMemoryFiles()
        userPersistence.saveWorkspace(
            currentWorkspace(),
            userId: userId,
            providerCredentials: providerCredentials
        )
        userPersistence.saveAudit(auditEvents)
        globalPersistence.saveAudit(auditEvents)
        saveGovernanceIfOwner()
        globalPersistence.saveUsers(users)
        globalPersistence.saveSession(session)
    }

    public func modelProviderSettings(for provider: String) -> ModelProviderSettings {
        ModelProviderProfiles.settings(
            provider: provider,
            profiles: providerProfiles,
            credentials: providerCredentials,
            activeProvider: modelProvider,
            activeModelId: modelId,
            activeBaseUrl: modelBaseUrl,
            activeFetched: fetchedModels,
            activeApiKey: apiKey,
            activeOAuthJSON: oauthJSON
        )
    }

    public func fetchedModels(for provider: String) -> [LocalModelRef] {
        modelProviderSettings(for: provider).fetchedModels
    }

    public func isProviderEnabled(_ provider: String) -> Bool {
        modelProviderSettings(for: provider).enabled
    }

    public func setProviderEnabled(_ provider: String, enabled: Bool) {
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var profile = providerProfiles[trimmed] ?? ModelProviderProfile()
        profile.enabled = enabled
        providerProfiles[trimmed] = profile
        save()
    }

    public func enabledModelSources() -> [EnabledProviderModels] {
        ModelCatalog.providers.compactMap { entry in
            guard isProviderEnabled(entry.provider) else { return nil }
            return EnabledProviderModels(
                provider: entry.provider,
                providerName: entry.providerName ?? entry.provider,
                fetched: modelProviderSettings(for: entry.provider).fetchedModels
            )
        }
    }

    /// Stash in-progress Connect form fields for the current provider without switching workspace default.
    public func updateModelProviderDraft(
        provider: String,
        modelId: String?,
        apiKey: String?,
        baseUrl: String?,
        models: [LocalModelRef]
    ) {
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else { return }

        var profile = providerProfiles[trimmedProvider] ?? ModelProviderProfile()
        if let modelId {
            let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.modelId = trimmed.isEmpty ? nil : trimmed
        }
        if let baseUrl, !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if ModelCatalog.usesCustomBase(trimmedProvider) {
                profile.baseUrl = (try? LocalProviders.normalizeBaseUrl(baseUrl, provider: trimmedProvider)) ?? baseUrl
            } else {
                profile.baseUrl = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !models.isEmpty {
            profile.fetchedModels = models
        }
        providerProfiles[trimmedProvider] = profile

        var cred = providerCredentials[trimmedProvider] ?? ProviderCredential()
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            cred.apiKey = trimmed.isEmpty ? nil : trimmed
        }
        providerCredentials[trimmedProvider] = cred

        if trimmedProvider == modelProvider {
            syncActiveProviderFields()
        }
    }

    private func syncActiveProviderFields() {
        guard let provider = modelProvider else { return }
        let settings = modelProviderSettings(for: provider)
        modelId = settings.modelId
        modelBaseUrl = settings.baseUrl
        fetchedModels = settings.fetchedModels
        apiKey = settings.apiKey
        oauthJSON = settings.oauthJSON
    }

    private func sleep(_ seconds: Double) async {
        let scaled = max(0.001, seconds * delayScale)
        try? await Task.sleep(for: .seconds(scaled))
    }

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

    // MARK: - Bots

    public var activeBot: Bot? {
        guard let id = activeBotId else { return bots.first(where: { !$0.hidden }) ?? bots.first }
        return bots.first(where: { $0.id == id }) ?? bots.first(where: { !$0.hidden }) ?? bots.first
    }

    @discardableResult
    public func createBot(
        name: String,
        title: String = "",
        description: String = "",
        instructions: String = "",
        parentBotId: String? = nil,
        enabledSkills: [String]? = nil,
        enabledTools: [String]? = nil
    ) -> Bot {
        let color = botColors[bots.count % botColors.count]
        let threadId = Ids.new()
        let bot = Bot(
            id: Ids.new(),
            name: name,
            title: title,
            description: description,
            instructions: instructions.isEmpty ? description : instructions,
            color: color,
            notifyOnFinish: true,
            parentBotId: parentBotId,
            threadId: threadId,
            enabledTools: enabledTools ?? (appConfig.defaultEnabledTools.isEmpty
                ? AgentToolCatalog.allIds
                : appConfig.defaultEnabledTools),
            enabledSkills: enabledSkills ?? BundledSkills.ids
        )
        bots.append(bot)
        threads[bot.id] = ThreadData(threadId: threadId)
        computers[bot.id] = ComputerStatus(
            botId: bot.id,
            kind: {
                switch appConfig.defaultComputerMode == .auto
                    ? (deployment.normalizedHost == .thisMac ? ComputerMode.thisMac : .inAppBrowser)
                    : appConfig.defaultComputerMode {
                case .thisMac: return .desktop
                case .off: return .none
                default: return deployment.sandboxKind
                }
            }(),
            state: .stopped
        )
        routines[bot.id] = []
        memory.append(
            MemoryDocument(
                id: Ids.new(),
                scope: "bot",
                botId: bot.id,
                path: "MEMORY.md",
                content: MemoryLedger.botTemplate
            )
        )
        try? botHome.write(botId: bot.id, path: MemoryFiles.botFileName, content: MemoryLedger.botTemplate)
        activeBotId = bot.id
        save()
        return bot
    }

    @discardableResult
    public func createBot(from template: BotTemplate, name: String? = nil) -> Bot {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return createBot(
            name: (label?.isEmpty == false) ? label! : template.name,
            title: template.title,
            description: template.blurb,
            instructions: template.instructions,
            enabledSkills: template.skillIds,
            enabledTools: template.toolIds
        )
    }

    public func updateBot(
        botId: String,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        workingFolder: String? = nil
    ) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let name { bots[idx].name = name }
        if let title { bots[idx].title = title }
        if let description { bots[idx].description = description }
        if let instructions { bots[idx].instructions = instructions }
        if let workingFolder {
            let trimmed = workingFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            bots[idx].workingFolder = trimmed.isEmpty ? nil : trimmed
        }
        bots[idx].updatedAt = .now
        save()
    }

    public func deleteBot(_ botId: String) {
        bots.removeAll { $0.id == botId }
        threads.removeValue(forKey: botId)
        computers.removeValue(forKey: botId)
        routines.removeValue(forKey: botId)
        memory.removeAll { $0.botId == botId }
        try? botHome.delete(botId: botId, path: MemoryFiles.botFileName)
        if activeBotId == botId {
            activeBotId = bots.first?.id
        }
        if panel == .settings || panel == .computer || panel == .routine {
            panel = nil
        }
        computerOpen = false
        canvasOpen = false
        if bots.isEmpty {
            route = .onboarding
            showHostPrompt = false
        }
        save()
    }

    public func sidebarPreview(for bot: Bot) -> String {
        if let thread = threads[bot.id], let last = thread.messages.last {
            let text = last.firstText
            if !text.isEmpty {
                return text.count > 80 ? String(text.prefix(80)) + "…" : text
            }
        }
        return bot.preview.isEmpty ? bot.title : bot.preview
    }

    public func sidebarStatus(for bot: Bot) -> String {
        if let run = threads[bot.id]?.run, run.status.isActive {
            return "working"
        }
        return bot.status == "working" ? "working" : "idle"
    }

    // MARK: - Threads / chat

    public func messages(for botId: String) -> [ThreadMessage] {
        messagesForActiveContext(botId: botId)
    }

    public func isRunActive(botId: String) -> Bool {
        threads[threadKey(for: botId)]?.run?.status.isActive == true
            || threads[threadKey(for: botId)]?.run?.status == .waitingInput
    }

    /// File tools resolve here for the current run (watcher watch path, else the bot folder).
    public func effectiveWorkingFolder(for bot: Bot) -> String? {
        let override = runWorkingFolderOverride[bot.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return bot.workingFolder
    }

    private func extraShellWriteRoots(for bot: Bot) -> [String] {
        guard let folder = effectiveWorkingFolder(for: bot)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return [] }
        let expanded = BotHomeStore.expandPath(folder)
        guard WorkingFolder.isTrusted(expanded, workingFolder: expanded) else { return [] }
        return [expanded]
    }

    public func send(botId: String, text: String, attaching files: [URL] = [], workingFolderOverride: String? = nil) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var imported: [String] = []
        for file in files {
            if let path = try? botHome.importFile(botId: botId, from: file) {
                imported.append(path)
            }
        }
        let attachedJPEG = ComposerImage.jpegBase64(from: files)
            ?? ComposerImage.jpegBase64(fromPathInText: trimmed)
        if let attachedJPEG, !attachedJPEG.isEmpty {
            // Path-only paste (`/Users/…/Screenshot.png`) → treat as an image caption.
            if ComposerImage.isImagePath(trimmed) || SlashCommand.looksLikeFilesystemPath(token: trimmed, full: trimmed) {
                trimmed = "Please describe this image."
            }
        }
        if !imported.isEmpty {
            let list = imported.map { "- `\($0)`" }.joined(separator: "\n")
            let note = "Attached files (in your home):\n\(list)"
            trimmed = trimmed.isEmpty ? note : "\(trimmed)\n\n\(note)"
        }
        guard !trimmed.isEmpty || !(attachedJPEG?.isEmpty ?? true) else { return }
        if trimmed.isEmpty {
            trimmed = "Please describe this image."
        }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let botSkills = skills(for: bot)

        switch SlashCommand.resolve(trimmed, skills: botSkills) {
        case .help(let listed):
            appendLocalAssistant(
                botId: botId,
                userText: trimmed,
                reply: SlashCommand.helpText(skills: listed)
            )
            return
        case .unknown(let name):
            appendLocalAssistant(
                botId: botId,
                userText: trimmed,
                reply: "Unknown command `/\(name)`. Type `/help` to list skills enabled for this bot."
            )
            return
        case .skill, .plain:
            break
        }

        let threadKey: String = {
            if let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        if threads[threadKey] == nil {
            threads[threadKey] = thread
        }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(trimmed)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq

        threads[threadKey] = thread
        bots[botIdx].preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        bots[botIdx].updatedAt = .now
        save()
        if let folder = workingFolderOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            runWorkingFolderOverride[botId] = (folder as NSString).expandingTildeInPath
        }
        launchRun(botId: botId, threadKey: threadKey, prompt: trimmed, promptImageJPEGBase64: attachedJPEG)
    }

    /// Slash / local replies that do not start an LLM run.
    private func appendLocalAssistant(botId: String, userText: String, reply: String) {
        let threadKey: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        if threads[threadKey] == nil {
            threads[threadKey] = thread
        }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(userText)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        let assistant = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text(reply)]
        )
        thread.messages.append(assistant)
        thread.cursor = assistant.seq
        threads[threadKey] = thread
        bots[botIdx].preview = reply.count > 80 ? String(reply.prefix(80)) + "…" : reply
        bots[botIdx].updatedAt = .now
        save()
    }

    private func launchRun(
        botId: String,
        threadKey: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) {
        guard var thread = threads[threadKey] else { return }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }
        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: "user"
        )
        thread.run = run
        threads[threadKey] = thread
        bots[botIdx].status = "working"
        bots[botIdx].updatedAt = .now
        save()
        let runId = run.id
        let imageNote = (promptImageJPEGBase64?.isEmpty == false) ? " +image" : ""
        appendRunLog(botId: botId, kind: "run", text: "start \(String(prompt.prefix(240)))\(imageNote)")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(
                botId: botId,
                threadKey: threadKey,
                runId: runId,
                prompt: prompt,
                promptImageJPEGBase64: promptImageJPEGBase64
            )
        }
        runTasks[runId] = task
    }

    private func runAgent(
        botId: String,
        threadKey: String,
        runId: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) async {
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        if canRunLLM(for: bot) {
            await runLLMAgent(
                botId: botId,
                threadKey: threadKey,
                runId: runId,
                prompt: prompt,
                promptImageJPEGBase64: promptImageJPEGBase64
            )
        } else {
            await runScriptedAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: prompt)
        }
    }

    private func canRunLLM(for bot: Bot) -> Bool {
        let provider = bot.modelProvider ?? modelProvider
        let settings = modelProviderSettings(for: provider ?? "")
        return LLMRouting.canRun(
            provider: provider,
            apiKey: settings.apiKey,
            baseUrl: settings.baseUrl,
            injectedClient: chatCompleter != nil
        ) || !(settings.oauthJSON?.isEmpty ?? true)
    }

    private func runLLMAgent(
        botId: String,
        threadKey: String,
        runId: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) async {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }

        let progressMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.progress("thinking…")],
            runId: runId
        )
        thread.messages.append(progressMsg)
        thread.cursor = progressMsg.seq
        threads[threadKey] = thread

        let provider = bot.modelProvider ?? modelProvider
        let providerSettings = modelProviderSettings(for: provider ?? ModelCatalog.defaultProvider)
        let selectedModel = bot.modelId ?? providerSettings.modelId ?? modelId
        let client: any ChatCompleting = chatCompleter ?? Self.defaultClient(for: provider)
        await warmMcpCatalog(bot: bot, prompt: prompt)
        hydratePromotedFromAdvertised(bot: bot)
        let tools = AgentToolCatalog.chatTools(
            enabledIds: bot.enabledTools,
            mcpServers: mcpServers,
            includeDelegation: true,
            skills: skills(for: bot),
            promotedMcp: Array(mcpPromotedTools.values),
            mcpAdvertised: mcpAdvertisedTools
        )
        var prior = thread.messages.filter { $0.id != progressMsg.id }
        if prior.last?.role == .user {
            prior.removeLast()
        }
        let textHistory = prior.compactMap { message -> AgentHistoryTurn? in
            let text = message.firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AgentHistoryTurn(role: message.role, text: text)
        }
        let priorLLM = thread.llmMessages
        let memoryRaw = memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
        let memoryText = MemoryLeanInject.excerpt(
            content: memoryRaw,
            query: prompt,
            mode: appConfig.memoryRelevanceMode
        )
        let sharedText = MemoryLeanInject.excerpt(
            content: sharedMemory,
            query: prompt,
            mode: appConfig.memoryRelevanceMode
        )
        let botSkills = skills(for: bot)
        let slash = SlashCommand.resolve(prompt, skills: botSkills)
        let pinFolderToRun = runWorkingFolderOverride[botId] != nil
        let agentPromptRaw: String
        let injected: [AgentSkill]
        switch slash {
        case .skill(let skill, let skillPrompt):
            agentPromptRaw = skillPrompt
            if pinFolderToRun {
                injected = []
            } else {
                var matched = SkillMarkdown.matching(botSkills, prompt: skillPrompt)
                matched.removeAll { $0.id == skill.id }
                injected = [skill] + matched
            }
        case .plain(let plain):
            agentPromptRaw = plain
            injected = pinFolderToRun ? [] : SkillMarkdown.matching(botSkills, prompt: plain)
        case .unknown, .help:
            agentPromptRaw = prompt
            injected = pinFolderToRun ? [] : SkillMarkdown.matching(botSkills, prompt: prompt)
        }
        let agentPrompt: String
        do {
            agentPrompt = try PrivacyFilter.applyForSend(
                agentPromptRaw,
                settings: appConfig.privacyFilter,
                logDirectory: userPersistence.root,
                logContext: "bot:\(botId)"
            )
        } catch {
            let message = error.localizedDescription
            let failMsg = ThreadMessage(
                id: progressMsg.id,
                threadId: thread.threadId,
                seq: progressMsg.seq,
                role: .bot,
                blocks: [.text(message)],
                runId: runId
            )
            if var t = threads[threadKey] {
                if let idx = t.messages.firstIndex(where: { $0.id == progressMsg.id }) {
                    t.messages[idx] = failMsg
                }
                t.run = nil
                threads[threadKey] = t
            }
            save()
            releaseWorkingFolderOverrideIfNeeded(botId: botId)
            return
        }
        let skillText = SkillMarkdown.catalogPrompt(from: botSkills, injected: injected)
        let homePath = (try? botHome.homeURL(botId: botId).path) ?? ""
        let computerNote = computerNote(for: bot)
        let workingFolderNote = WorkingFolder.promptNote(
            effectiveWorkingFolder(for: bot),
            scopedToRun: pinFolderToRun
        )

        var blocks: [MessageBlock] = []
        var pause: AgentPause?
        var inputTokens = 0
        var outputTokens = 0
        var promptTokens = 0
        var steps = 0
        var replyText = ""
        var failed = false
        var failureReason: String?
        var transcript: [ChatMessage] = []

        do {
            let endpoint: ModelEndpoint
            if chatCompleter != nil {
                endpoint = (try? LLMRouting.endpoint(
                    provider: provider,
                    modelId: selectedModel,
                    apiKey: providerSettings.apiKey,
                    baseUrl: providerSettings.baseUrl
                )) ?? ModelEndpoint(
                    provider: provider ?? "injected",
                    model: selectedModel ?? "test",
                    baseURL: "https://localhost/v1",
                    apiKey: "local"
                )
            } else {
                var resolvedKey = providerSettings.apiKey
                if let token = await DeviceCodeAuth.resolveAccessToken(
                    apiKey: providerSettings.apiKey,
                    oauthJSON: providerSettings.oauthJSON,
                    provider: provider ?? ""
                ) {
                    resolvedKey = token
                }
                endpoint = try LLMRouting.endpoint(
                    provider: provider,
                    modelId: selectedModel,
                    apiKey: resolvedKey,
                    baseUrl: providerSettings.baseUrl
                )
            }
            let progressId = progressMsg.id
            let stallMs = max(0, appConfig.agentStallTimeoutMs)
            let loopRequest = AgentLoopRequest(
                endpoint: endpoint,
                botName: bot.name,
                botTitle: bot.title,
                instructions: bot.instructions,
                memory: memoryText,
                sharedMemory: sharedText,
                skillCatalog: skillText,
                homePath: homePath,
                history: textHistory,
                priorMessages: priorLLM,
                prompt: agentPrompt,
                promptImageJPEGBase64: promptImageJPEGBase64,
                tools: tools,
                maxSteps: 48,
                charBudget: AgentLoopRequest.charBudget(provider: provider),
                computerNote: computerNote,
                workingFolderNote: workingFolderNote,
                stallMs: stallMs
            )
            let execute: @Sendable (String, String) async -> AgentToolCallResult = { [weak self] name, arguments in
                guard let self else {
                    return AgentToolCallResult(output: "store released")
                }
                return await self.executeAgentTool(
                    name: name,
                    argumentsJSON: arguments,
                    botId: botId,
                    depth: 0,
                    endpoint: endpoint,
                    client: client
                )
            }
            let result: AgentLoopResult
            if bot.runtime == .agui, let agui = bot.aguiURL?.trimmingCharacters(in: .whitespacesAndNewlines), !agui.isEmpty {
                var aguiMessages: [ChatMessage] = [.system(AgentLoop.systemPrompt(for: loopRequest))]
                aguiMessages.append(contentsOf: priorLLM.filter { $0.role != "system" })
                aguiMessages.append(
                    ChatMessage(role: "user", content: agentPrompt, imageJPEGBase64: promptImageJPEGBase64)
                )
                var headers: [String: String] = [:]
                if let token = connectionSecrets["agui:\(botId)"], !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                result = try await AguiRuntime.run(
                    input: AguiClient.RunInput(
                        url: agui,
                        headers: headers,
                        threadId: thread.threadId,
                        runId: runId,
                        messages: aguiMessages,
                        tools: tools,
                        stallMs: stallMs
                    ),
                    onDelta: { [weak self] delta in
                        Task { @MainActor in
                            self?.appendStreamDelta(threadKey: threadKey, runId: runId, messageId: progressId, delta: delta)
                        }
                    },
                    onTool: { [weak self] name, _, toolResult in
                        Task { @MainActor in
                            self?.appendRunLog(botId: botId, kind: "tool", text: "\(name) \(String(toolResult.output.prefix(400)))")
                            self?.appendLiveTool(threadKey: threadKey, runId: runId, name: name, result: toolResult)
                        }
                    },
                    execute: execute
                )
            } else {
                result = try await AgentLoop.run(
                    client: client,
                    request: loopRequest,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in
                            self?.appendStreamDelta(threadKey: threadKey, runId: runId, messageId: progressId, delta: delta)
                        }
                    },
                    onStep: { [weak self] step, max in
                        Task { @MainActor in
                            self?.setThinkingProgress(
                                threadKey: threadKey,
                                runId: runId,
                                messageId: progressId,
                                text: "thinking… step \(step)/\(max)"
                            )
                        }
                    },
                    onTool: { [weak self] name, _, toolResult in
                        Task { @MainActor in
                            self?.appendRunLog(botId: botId, kind: "tool", text: "\(name) \(String(toolResult.output.prefix(400)))")
                            self?.appendLiveTool(threadKey: threadKey, runId: runId, name: name, result: toolResult)
                        }
                    },
                    execute: execute
                )
            }
            blocks.append(contentsOf: result.blocks.filter { block in
                // Live tool messages already show status cards; keep interactive blocks only.
                switch block {
                case .card: return false
                case .ask, .approval, .choice, .connect, .component, .computer: return true
                default: return true
                }
            })
            replyText = result.text
            pause = result.pause
            inputTokens = result.inputTokens
            outputTokens = result.outputTokens
            promptTokens = result.promptTokens
            steps = result.steps
            transcript = result.messages
            if result.failed {
                failed = true
                failureReason = result.failureReason
                if let reason = result.failureReason {
                    appendRunLog(botId: botId, kind: "error", text: reason)
                }
            }
        } catch is CancellationError {
            finishCancelled(botId: botId, threadKey: threadKey, runId: runId)
            runTasks.removeValue(forKey: runId)
            return
        } catch {
            failed = true
            replyText = "I couldn't complete that: \(error.localizedDescription)"
            appendRunLog(botId: botId, kind: "error", text: error.localizedDescription)
        }

        guard !Task.isCancelled else {
            finishCancelled(botId: botId, threadKey: threadKey, runId: runId)
            runTasks.removeValue(forKey: runId)
            return
        }
        guard var thread2 = threads[threadKey], thread2.run?.id == runId else { return }
        thread2.messages.removeAll { $0.id == progressMsg.id }

        if groups.contains(where: { $0.id == threadKey }) {
            replyText = "**\(bot.name):** \(replyText)"
        }
        if !replyText.isEmpty {
            blocks.insert(.text(replyText), at: 0)
        } else if blocks.isEmpty {
            blocks.append(.text("done."))
        }
        if inputTokens > 0 || outputTokens > 0 || steps > 0 {
            blocks.append(.meta("\(steps) steps · \(inputTokens) in / \(outputTokens) out"))
        }

        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread2.threadId,
            seq: thread2.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        thread2.messages.append(botMsg)
        thread2.cursor = botMsg.seq
        if !transcript.isEmpty {
            thread2.llmMessages = transcript
        }

        if pause == .takeover {
            thread2.run?.status = .waitingTakeover
        } else if case .approval(let tool, let detail, let arguments) = pause {
            thread2.run?.status = .waitingInput
            thread2.pendingTool = PendingAgentTool(
                name: Self.approvalFunctionName(tool),
                arguments: arguments,
                tool: tool,
                detail: detail
            )
        } else if pause == .waitingInput || blocks.contains(where: {
            if case .approval(_, _, .pending) = $0 { return true }
            if case .choice = $0 { return true }
            if case .ask = $0 { return true }
            return false
        }) {
            thread2.run?.status = .waitingInput
        } else if failed {
            thread2.run?.status = .failed
            thread2.run?.error = failureReason ?? replyText
            thread2.run?.completedAt = .now
            if failureReason?.contains("AGENT_STREAM_STALLED") == true {
                recordAudit(
                    type: .agentStreamStalled,
                    botId: botId,
                    tool: nil,
                    reason: replyText,
                    allowed: false,
                    forwarded: false
                )
            }
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[threadKey] = thread2
        finalizeBotPreview(botId: botId, threadKey: threadKey, message: botMsg)
        usage.append(
            UsageRecord(
                id: Ids.new(),
                botId: botId,
                runId: runId,
                provider: provider ?? ModelCatalog.defaultProvider,
                model: selectedModel ?? ModelCatalog.defaultModelId,
                promptTokens: promptTokens > 0 ? promptTokens : nil,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        )
        save()
        runTasks.removeValue(forKey: runId)
        finishRoutineIfNeeded(
            botId: botId,
            threadKey: threadKey,
            status: thread2.run?.status,
            error: thread2.run?.error ?? (failed ? replyText : nil)
        )
        announceFinished(botId: botId, text: replyText, status: thread2.run?.status)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    private func runScriptedAgent(botId: String, threadKey: String, runId: String, prompt: String) async {
        await sleep(0.9)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }

        let progressMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.progress("working…")],
            runId: runId
        )
        thread.messages.append(progressMsg)
        thread.cursor = progressMsg.seq
        threads[threadKey] = thread

        await sleep(0.7)
        guard !Task.isCancelled else {
            await MainActor.run { self.finishCancelled(botId: botId, threadKey: threadKey, runId: runId) }
            return
        }
        guard var thread2 = threads[threadKey], thread2.run?.id == runId else { return }

        thread2.messages.removeAll { $0.id == progressMsg.id }

        let reply = ScriptedRuntime.reply(to: prompt, customTools: customTools, mcpServers: mcpServers)
        var blocks: [MessageBlock] = []
        var actionToRun = reply.action

        if let proposed = actionToRun,
           let bot = bots.first(where: { $0.id == botId }),
           !bot.isToolEnabled(proposed.toolId) {
            let label = AgentToolCatalog.label(for: proposed.toolId, custom: customTools, mcpServers: mcpServers)
            blocks.append(.text("that tool is disabled for me (**\(label)**). enable it in Settings → Tools."))
            actionToRun = nil
        } else {
            blocks.append(.text(reply.text))
        }

        await applyAction(actionToRun, botId: botId, blocks: &blocks, thread: &thread2, runId: runId)

        let lowerPrompt = prompt.lowercased()
        if lowerPrompt.contains("run shell") {
            let bot = bots.first(where: { $0.id == botId })
            if bot?.isToolEnabled("shell") != true {
                blocks.append(.text("shell is disabled for me. enable it in Settings → Tools."))
            } else {
                let tool = "shell.exec"
                if bot?.autoApprove == true || bot?.alwaysAllowTools.contains(tool) == true {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .alwaysAllowed))
                } else {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .pending))
                }
            }
        }

        if lowerPrompt.contains("choose") || lowerPrompt.contains("pick one") || lowerPrompt.contains("which option") {
            blocks.append(
                .choice(
                    question: "Which should I do?",
                    subtitle: "Pick one to continue",
                    options: [
                        ChoiceOption(id: "a", letter: "A", label: "Continue as planned"),
                        ChoiceOption(id: "b", letter: "B", label: "Try a safer approach"),
                        ChoiceOption(id: "c", letter: "C", label: "Ask me first next time"),
                    ]
                )
            )
        }

        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread2.threadId,
            seq: thread2.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        thread2.messages.append(botMsg)
        thread2.cursor = botMsg.seq

        if case .takeover = actionToRun {
            thread2.run?.status = .waitingTakeover
        } else if case .subagent = actionToRun {
            thread2.run?.status = .running
        } else if blocks.contains(where: {
            if case .approval(_, _, .pending) = $0 { return true }
            if case .choice = $0 { return true }
            return false
        }) {
            thread2.run?.status = .waitingInput
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[threadKey] = thread2
        finalizeBotPreview(botId: botId, threadKey: threadKey, message: botMsg)

        usage.append(
            UsageRecord(
                id: Ids.new(),
                botId: botId,
                runId: runId,
                provider: modelProvider ?? ModelCatalog.defaultProvider,
                model: modelId ?? ModelCatalog.defaultModelId,
                promptTokens: 12,
                inputTokens: 12,
                outputTokens: 40
            )
        )
        save()

        if case .subagent(let task) = actionToRun {
            await completeSubagent(botId: botId, threadKey: threadKey, runId: runId, messageId: botMsg.id, task: task)
        }

        runTasks.removeValue(forKey: runId)
        announceFinished(botId: botId, text: botMsg.firstText, status: thread2.run?.status)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    private func setThinkingProgress(threadKey: String, runId: String, messageId: String, text: String) {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if case .progress(let existing) = thread.messages[idx].blocks.first {
            if existing.hasPrefix("thinking…") || existing.isEmpty {
                thread.messages[idx].blocks = [.progress(text)]
                threads[threadKey] = thread
            }
        }
    }

    private func appendStreamDelta(threadKey: String, runId: String, messageId: String, delta: String) {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var text = ""
        if case .progress(let existing) = thread.messages[idx].blocks.first {
            if existing.hasPrefix("thinking…") {
                text = ""
            } else {
                text = existing
            }
        } else if case .text(let existing) = thread.messages[idx].blocks.first {
            text = existing
        }
        text += delta
        thread.messages[idx].blocks = [.progress(text)]
        threads[threadKey] = thread
    }

    private func finalizeBotPreview(botId: String, threadKey: String, message: ThreadMessage) {
        let status = threads[threadKey]?.run?.status
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            let preview = message.firstText
            bots[idx].preview = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
            if status?.isActive != true && status != .waitingInput && status != .waitingTakeover {
                bots[idx].status = "idle"
                releaseWorkingFolderOverrideIfNeeded(botId: botId)
            }
            bots[idx].updatedAt = .now
            if activeBotId != botId {
                bots[idx].unread = true
            }
        }
        if let gIdx = groups.firstIndex(where: { $0.id == threadKey }) {
            groups[gIdx].preview = message.firstText
        }
    }

    private func executeAgentTool(
        name: String,
        argumentsJSON: String,
        botId: String,
        depth: Int,
        endpoint: ModelEndpoint,
        client: any ChatCompleting,
        approved: Bool = false
    ) async -> AgentToolCallResult {
        let args = JSONValue.parseObject(argumentsJSON)
        func s(_ keys: String...) -> String {
            for key in keys {
                if let value = JSONValue.object(args).stringValue(key) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return ""
        }

        guard let bot = bots.first(where: { $0.id == botId }) else {
            return AgentToolCallResult(output: "Unknown bot.")
        }
        func resolveToolPath(_ raw: String) -> String {
            WorkingFolder.resolve(raw, workingFolder: effectiveWorkingFolder(for: bot))
        }
        func hostGate(tool: String, paths: String..., argumentsJSON: String) -> AgentToolCallResult? {
            for path in paths where BotHomeStore.isHostPath(path) {
                if BotHomeStore.isDeniedHostPath(path) {
                    return AgentToolCallResult(output: "\(tool) failed: \(BotHomeError.hostDenied.localizedDescription)")
                }
                if WorkingFolder.isTrusted(path, workingFolder: effectiveWorkingFolder(for: bot)) {
                    continue
                }
                if let gated = gatedWrite(
                    tool: tool,
                    detail: path,
                    argumentsJSON: argumentsJSON,
                    bot: bot,
                    approved: approved
                ) {
                    return gated
                }
            }
            return nil
        }

        let enabledMcp = enabledMcpServers(bot: bot)
        if name != "mcp_call", name != "mcp_list_tools",
           !AgentToolCatalog.builtinIds.contains(name),
           name != "web_fetch",
           let hit = McpToolRouting.resolveDirectTool(
            name: name,
            promoted: mcpPromotedTools,
            servers: enabledMcp,
            advertised: advertisedMcpTools(for: bot)
           ) {
            switch hit {
            case .promoted(let promoted):
                let rewritten = McpCatalogPromote.mcpCallArguments(promoted: promoted, raw: args)
                return await executeAgentTool(
                    name: "mcp_call",
                    argumentsJSON: JSONValue.object(rewritten).jsonString(),
                    botId: botId,
                    depth: depth,
                    endpoint: endpoint,
                    client: client,
                    approved: approved
                )
            case .advertised(let serverId, let toolName):
                var rewritten = args
                rewritten["server"] = .string(serverId)
                rewritten["tool"] = .string(toolName)
                return await executeAgentTool(
                    name: "mcp_call",
                    argumentsJSON: JSONValue.object(rewritten).jsonString(),
                    botId: botId,
                    depth: depth,
                    endpoint: endpoint,
                    client: client,
                    approved: approved
                )
            case .missingGateway(let tool):
                let output = McpToolRouting.missingGatewayMessage(tool: tool, enabled: enabledMcp)
                appendRunLog(botId: botId, kind: "tool", text: output)
                return AgentToolCallResult(output: output)
            }
        }

        let catalogId: String = {
            switch name {
            case "web_fetch": return "web_search"
            case "mcp_list_tools", "mcp_call": return ""
            default:
                if CanvasBoardStore.toolIds.contains(name) { return "" }
                if ArtifactStore.toolIds.contains(name) { return "" }
                if mcpPromotedTools[name] != nil { return "" }
                if AgentToolCatalog.builtinIds.contains(name) { return name }
                return ""
            }
        }()
        if !catalogId.isEmpty, !bot.isToolEnabled(catalogId) {
            let hasMcp = !enabledMcp.isEmpty
            let context = McpFallbackContext.from(
                servers: enabledMcp,
                advertised: advertisedMcpTools(for: bot),
                firstClassNames: Array(mcpPromotedTools.keys)
            )
            let output = DisabledBuiltinFallback.toolResult(
                tool: name,
                argumentsJSON: argumentsJSON,
                hasMcp: hasMcp,
                context: context
            )
            appendRunLog(botId: botId, kind: "tool", text: output)
            return AgentToolCallResult(
                output: output,
                blocks: [.card(lines: [
                    CardLine(k: name, v: hasMcp ? "disabled — use MCP" : output),
                ])]
            )
        }

        if let promoted = mcpPromotedTools[name] {
            let rewritten = McpCatalogPromote.mcpCallArguments(promoted: promoted, raw: args)
            return await executeAgentTool(
                name: "mcp_call",
                argumentsJSON: JSONValue.object(rewritten).jsonString(),
                botId: botId,
                depth: depth,
                endpoint: endpoint,
                client: client,
                approved: approved
            )
        }

        if ActionGateway.isComputerTool(name), computers[botId]?.controlHolder == .user {
            let refusal = ActionGateway.humanDrivingRefusal(tool: name)
            recordAudit(
                type: .computerActionRefused,
                botId: botId,
                tool: name,
                reason: refusal.reason,
                allowed: false,
                forwarded: false
            )
            return AgentToolCallResult(
                output: refusal.output,
                blocks: [.card(lines: [CardLine(k: "refused", v: refusal.reason)])]
            )
        }

        if name == "mcp_call" || name == "mcp_list_tools" {
            let server = resolveMcpServer(s("server"), toolName: s("tool", "name"), bot: bot)
            if let server {
                let plugin = server.toolId
                let toolName = name == "mcp_list_tools" ? nil : s("tool", "name")
                if !PluginGrant.allows(grants: pluginGrants, botId: botId, plugin: plugin, tool: toolName) {
                    let reason = "This bot is not granted \(plugin)\(toolName.map { "/\($0)" } ?? "")."
                    recordAudit(
                        type: .mcpCallRejected,
                        botId: botId,
                        tool: name,
                        reason: reason,
                        allowed: false,
                        forwarded: false
                    )
                    return AgentToolCallResult(output: reason)
                }
            }
        }

        if name == "present_component" {
            let componentId = s("id", "name")
            if !AgentComponentCatalog.isPublished(componentId, extras: sandboxComponents) {
                return AgentToolCallResult(output: "Unknown component \(componentId).")
            }
            if !bot.enabledComponents.contains(componentId) {
                let reason = "Component \(componentId) is withheld from this bot."
                recordAudit(type: .componentRefused, botId: botId, tool: name, reason: reason, allowed: false, forwarded: false)
                return AgentToolCallResult(output: reason)
            }
            let authored = sandboxComponents.first { $0.id == componentId }
            let needsData = componentId == "activity" || componentId == "refusals"
                || (authored?.dataFunctions.isEmpty == false)
            if needsData {
                let dataPlugin = "component-data:\(componentId)"
                if !PluginGrant.allows(grants: pluginGrants, botId: botId, plugin: dataPlugin, tool: nil) {
                    let reason = "This bot is not granted \(dataPlugin)."
                    recordAudit(type: .componentRefused, botId: botId, tool: name, reason: reason, allowed: false, forwarded: false)
                    return AgentToolCallResult(output: reason)
                }
            }
        }

        let mcpServer = (name == "mcp_call" || name == "mcp_list_tools")
            ? resolveMcpServer(s("server"), toolName: s("tool", "name"), bot: bot)
            : nil
        let advertised: Bool = {
            if name == "mcp_list_tools" { return true }
            guard name == "mcp_call", let server = mcpServer else { return false }
            let toolName = s("tool", "name")
            return mcpAdvertisedTools[server.id]?.contains(toolName) == true
                || mcpPromotedTools.values.contains {
                    $0.serverId == server.id
                        && ($0.chatName == toolName
                            || $0.executeTool == toolName
                            || $0.injectName == toolName)
                }
        }()
        let resolved = resolvePolicyElement(tool: name, argumentsJSON: argumentsJSON, botId: botId)
        let pageURL = computers[botId]?.lastPageURL ?? ""
        let pageHost = URL(string: pageURL)?.host ?? ""
        let context = ActionGateway.context(
            tool: name,
            argumentsJSON: argumentsJSON,
            botId: botId,
            actorId: session?.userId ?? "local",
            pageURL: pageURL,
            pageHost: pageHost,
            element: resolved,
            mcpServer: mcpServer,
            advertisedMcpTool: advertised
        )
        let decision = ActionGateway.decide(policy: actionPolicy, context: context)
        recordAudit(
            type: ActionGateway.auditType(for: name, decision: decision, failed: false),
            botId: botId,
            tool: name,
            reason: decision.reason,
            allowed: decision.allowed,
            forwarded: decision.forward,
            matched: decision.matched,
            source: decision.source.rawValue,
            attributes: context.mcp.map { mcp in
                ["mcp.server": .string(mcp.server), "mcp.tool": .string(mcp.tool), "mcp.effect": .string(mcp.effect.rawValue)]
            } ?? [:]
        )
        if !decision.forward {
            return AgentToolCallResult(
                output: decision.reason,
                blocks: [.card(lines: [
                    CardLine(k: "policy", v: "refused"),
                    CardLine(k: "rule", v: decision.matched ?? "default deny"),
                ])]
            )
        }

        switch name {
        case "write_file":
            let path = resolveToolPath(s("path"))
            let content = s("content")
            guard !path.isEmpty else { return AgentToolCallResult(output: "path is required") }
            if let gated = hostGate(tool: "write_file.host", paths: path, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                let before = (try? botHome.readFlexible(botId: botId, path: path)) ?? ""
                try botHome.writeFlexible(botId: botId, path: path, content: content)
                if !BotHomeStore.isHostPath(path) {
                    upsertFile(path: path, content: content)
                    refreshFilesMirror(botId: botId)
                    ingestMemoryFileIfNeeded(botId: botId, path: path)
                }
                let diff = TextDiff.unified(before: before, after: content, path: path)
                return AgentToolCallResult(
                    output: "Wrote \(path) (\(content.count) chars).\n\(diff)",
                    blocks: [.card(lines: [
                        CardLine(k: "wrote", v: path),
                        CardLine(k: "diff", v: String(diff.prefix(400))),
                    ])]
                )
            } catch {
                return AgentToolCallResult(output: "Write failed: \(error.localizedDescription)")
            }

        case "read_file":
            let path = resolveToolPath(s("path"))
            guard !path.isEmpty else { return AgentToolCallResult(output: "path is required") }
            if let gated = hostGate(tool: "read_file.host", paths: path, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                let content = try botHome.readFlexible(botId: botId, path: path)
                return AgentToolCallResult(
                    output: content,
                    blocks: [.card(lines: [
                        CardLine(k: "read", v: path),
                        CardLine(k: "bytes", v: "\(content.count)"),
                    ])]
                )
            } catch {
                return AgentToolCallResult(output: "Read failed: \(error.localizedDescription)")
            }

        case "edit_file":
            let path = resolveToolPath(s("path"))
            let content = s("content")
            let append = s("mode").lowercased() == "append"
            guard !path.isEmpty else { return AgentToolCallResult(output: "path is required") }
            if let gated = hostGate(tool: "edit_file.host", paths: path, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                try botHome.editFlexible(botId: botId, path: path, content: content, mode: append ? .append : .replace)
                if !BotHomeStore.isHostPath(path) {
                    refreshFilesMirror(botId: botId)
                    ingestMemoryFileIfNeeded(botId: botId, path: path)
                }
                return AgentToolCallResult(
                    output: "\(append ? "Appended" : "Edited") \(path).",
                    blocks: [.card(lines: [CardLine(k: append ? "appended" : "edited", v: path)])]
                )
            } catch {
                return AgentToolCallResult(output: "Edit failed: \(error.localizedDescription)")
            }

        case "move_file":
            let from = resolveToolPath(s("from", "source"))
            let to = resolveToolPath(s("to", "destination"))
            guard !from.isEmpty, !to.isEmpty else {
                return AgentToolCallResult(output: "from and to are required")
            }
            if let gated = hostGate(tool: "move_file.host", paths: from, to, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                try botHome.moveFlexible(botId: botId, from: from, to: to)
                if !BotHomeStore.isHostPath(from), !BotHomeStore.isHostPath(to) {
                    refreshFilesMirror(botId: botId)
                }
                return AgentToolCallResult(
                    output: "Moved \(from) → \(to).",
                    blocks: [.card(lines: [CardLine(k: "moved", v: "\(from) → \(to)")])]
                )
            } catch {
                return AgentToolCallResult(output: "Move failed: \(error.localizedDescription)")
            }

        case "delete_file":
            let path = resolveToolPath(s("path"))
            guard !path.isEmpty else { return AgentToolCallResult(output: "path is required") }
            if let gated = hostGate(tool: "delete_file.host", paths: path, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                try botHome.deleteFlexible(botId: botId, path: path)
                if !BotHomeStore.isHostPath(path) {
                    refreshFilesMirror(botId: botId)
                    if URL(fileURLWithPath: path).lastPathComponent == MemoryFiles.botFileName {
                        try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: MemoryLedger.botTemplate)
                        ingestMemoryFileIfNeeded(botId: botId, path: MemoryFiles.botFileName)
                    }
                }
                return AgentToolCallResult(
                    output: "Deleted \(path).",
                    blocks: [.card(lines: [CardLine(k: "deleted", v: path)])]
                )
            } catch {
                return AgentToolCallResult(output: "Delete failed: \(error.localizedDescription)")
            }

        case "list_files":
            let directory = resolveToolPath(s("directory", "path"))
            if let gated = hostGate(tool: "list_files.host", paths: directory, argumentsJSON: argumentsJSON) {
                return gated
            }
            do {
                let entries = try botHome.listFlexible(botId: botId, directory: directory)
                let listing = entries.map { "\($0.isDirectory ? "dir" : "file") \($0.path)" }.joined(separator: "\n")
                let lines = entries.prefix(20).map {
                    CardLine(k: $0.isDirectory ? "dir" : "file", v: $0.path)
                }
                let emptyHint = BotHomeStore.isHostPath(directory)
                    ? "(empty)"
                    : "(empty) — no such folder in bot home. For a folder on this Mac, pass an absolute path such as ~/.agents/skills."
                return AgentToolCallResult(
                    output: listing.isEmpty ? emptyHint : listing,
                    blocks: [.card(lines: lines.isEmpty ? [CardLine(k: "home", v: emptyHint)] : Array(lines))]
                )
            } catch {
                return AgentToolCallResult(output: "List failed: \(error.localizedDescription)")
            }

        case "web_search":
            let query = s("query", "q")
            guard !query.isEmpty else { return AgentToolCallResult(output: "query is required") }
            do {
                let results = try await WebSearch.search(query: query, limit: 5, braveKey: appConfig.braveSearchKey)
                if results.isEmpty {
                    return AgentToolCallResult(
                        output: "No results for \(query). Do not retry similar queries this turn unless you have a new proper noun. If this is about GrizzyBot Settings, answer from this Mac.",
                        blocks: [.card(lines: [CardLine(k: "search", v: query), CardLine(k: "results", v: "no results")])]
                    )
                }
                var lines = [CardLine(k: "search", v: query)]
                for (idx, item) in results.enumerated() {
                    lines.append(CardLine(k: "\(idx + 1). \(item.title)", v: item.snippet.isEmpty ? item.url : item.snippet))
                }
                let text = results.map { "• \($0.title) — \($0.snippet)\n  \($0.url)" }.joined(separator: "\n")
                return AgentToolCallResult(output: text, blocks: [.card(lines: lines)])
            } catch {
                let detail = error.localizedDescription
                return AgentToolCallResult(
                    output: detail.contains("Search") ? detail : "Search failed: \(detail)",
                    blocks: [.card(lines: [CardLine(k: "search", v: query), CardLine(k: "results", v: "blocked")])]
                )
            }

        case "web_fetch":
            let url = s("url")
            guard !url.isEmpty else { return AgentToolCallResult(output: "url is required") }
            do {
                let body = try await WebSearch.fetch(url: url)
                return AgentToolCallResult(
                    output: body.isEmpty ? "(empty page)" : body,
                    blocks: [.card(lines: [CardLine(k: "fetched", v: url)])]
                )
            } catch {
                let detail = error.localizedDescription
                return AgentToolCallResult(
                    output: detail.lowercased().contains("fetch failed") ? detail : "Fetch failed: \(detail)",
                    blocks: [.card(lines: [CardLine(k: "web_fetch", v: detail)])]
                )
            }

        case "shell":
            let command = s("command", "cmd")
            let cwd = s("cwd")
            let timeout = BotHomeStore.ShellTimeout.parse(s("timeout_seconds", "timeout"))
            guard !command.isEmpty else { return AgentToolCallResult(output: "command is required") }
            if let gated = gatedWrite(
                tool: "shell.exec",
                detail: command,
                argumentsJSON: argumentsJSON,
                bot: bot,
                approved: approved
            ) {
                return gated
            }
            let allowed = bot.autoApprove || bot.alwaysAllowTools.contains("shell.exec")
            do {
                let result = try await botHome.runShell(
                    botId: botId,
                    command: command,
                    cwd: cwd,
                    timeout: timeout,
                    extraWriteRoots: extraShellWriteRoots(for: bot)
                )
                let status: ApprovalStatus = allowed ? .alwaysAllowed : .allowed
                return AgentToolCallResult(
                    output: result.combined,
                    blocks: [
                        .approval(tool: "shell.exec", detail: command, status: status),
                        .card(lines: [
                            CardLine(k: "exit", v: "\(result.exitCode)"),
                            CardLine(k: "cwd", v: cwd.isEmpty ? "." : cwd),
                            CardLine(k: "out", v: String(result.combined.prefix(500))),
                        ]),
                    ]
                )
            } catch {
                return AgentToolCallResult(output: "Shell failed: \(error.localizedDescription)")
            }

        case "remember":
            let content = s("content", "text")
            guard !content.isEmpty else { return AgentToolCallResult(output: "content is required") }
            let scope = s("scope").lowercased()
            let shared = scope == "shared" || scope == "workspace"
            let pin = s("pin").lowercased() == "true" || scope == "pin"
            let result = rememberFact(botId: botId, text: content, shared: shared, pin: pin)
            switch result {
            case .rejectedSecret:
                return AgentToolCallResult(output: "Refused — that looks like a secret. Store keys in Settings, not memory.")
            case .empty:
                return AgentToolCallResult(output: "content is required")
            case .unchanged:
                return AgentToolCallResult(
                    output: "Already in \(shared ? "shared" : "bot") memory.",
                    blocks: [.card(lines: [
                        CardLine(k: "memory", v: String(content.prefix(200))),
                        CardLine(k: "scope", v: shared ? "shared" : "bot"),
                        CardLine(k: "pin", v: pin ? "true" : "false"),
                    ])]
                )
            case .updated(let previous):
                return AgentToolCallResult(
                    output: "Updated \(shared ? "shared" : "bot") memory (replaced \"\(previous)\").",
                    blocks: [.card(lines: [
                        CardLine(k: "memory", v: String(content.prefix(200))),
                        CardLine(k: "scope", v: shared ? "shared" : "bot"),
                        CardLine(k: "pin", v: pin ? "true" : "false"),
                    ])]
                )
            case .inserted:
                return AgentToolCallResult(
                    output: shared ? "Remembered in shared workspace memory." : "Remembered.",
                    blocks: [.card(lines: [
                        CardLine(k: "memory", v: String(content.prefix(200))),
                        CardLine(k: "scope", v: shared ? "shared" : "bot"),
                        CardLine(k: "pin", v: pin ? "true" : "false"),
                    ])]
                )
            }

        case "forget":
            let query = s("query", "content", "text")
            guard !query.isEmpty else { return AgentToolCallResult(output: "query is required") }
            let scope = s("scope").lowercased()
            let shared = scope == "shared" || scope == "workspace"
            let removed = forgetFacts(botId: botId, query: query, shared: shared)
            if removed.isEmpty {
                return AgentToolCallResult(output: "No memory matched \(query).")
            }
            return AgentToolCallResult(
                output: "Forgot \(removed.count) fact(s): \(removed.joined(separator: "; ")).",
                blocks: [.card(lines: removed.prefix(8).map { CardLine(k: "forgot", v: $0) })]
            )

        case "search_memory":
            let query = s("query", "q")
            guard !query.isEmpty else { return AgentToolCallResult(output: "query is required") }
            let hits = MemoryHybridSearch.search(documents: memory, query: query, botId: botId)
            if hits.isEmpty {
                return AgentToolCallResult(output: "No memory hits for \(query).")
            }
            let text = hits.map { "• [\($0.scope)/\($0.path)] \($0.snippet)" }.joined(separator: "\n")
            return AgentToolCallResult(
                output: text,
                blocks: [.card(lines: hits.prefix(8).map { CardLine(k: $0.path, v: $0.snippet) })]
            )

        case "search_knowledge":
            let query = s("query", "q")
            guard !query.isEmpty else { return AgentToolCallResult(output: "query is required") }
            await syncPluginKnowledge(query: query, botId: botId)
            let docs = knowledgeDocuments()
            let hits = KnowledgePlane.search(
                query: query,
                botId: botId,
                sources: knowledgeSources,
                documents: docs
            )
            recordAudit(
                type: .knowledgeSearched,
                botId: botId,
                tool: "search_knowledge",
                reason: "query \(query.count) chars",
                allowed: true,
                forwarded: true,
                attributes: ["chars": .number(Double(query.count))]
            )
            if hits.isEmpty {
                return AgentToolCallResult(output: "No knowledge hits for that query.")
            }
            let text = hits.map { "• [\($0.sourceName)] \($0.path): \($0.snippet)" }.joined(separator: "\n")
            return AgentToolCallResult(
                output: text,
                blocks: [.card(lines: hits.prefix(8).map { CardLine(k: $0.sourceName, v: $0.snippet) })]
            )

        case "present_component":
            let componentId = s("id", "name")
            let authored = sandboxComponents.first { $0.id == componentId && $0.published }
            var title = s("title")
            var fields: [ComponentField] = authored?.payload.fields ?? []
            var items: [String] = authored?.payload.items ?? []
            if let data = s("fields").data(using: .utf8),
               let parsed = try? JSONDecoder().decode([ComponentField].self, from: data) {
                fields = parsed
            }
            if let data = s("items").data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                items = parsed
            }
            if title.isEmpty {
                title = authored?.title ?? componentId
            }
            let dataFns = authored?.dataFunctions ?? (
                componentId == "activity" || componentId == "refusals" ? [componentId] : []
            )
            if dataFns.contains("activity") || componentId == "activity" {
                let rows = AuditLog.recent(auditEvents, limit: 8, botId: botId)
                items = rows.map { "\($0.type.rawValue): \($0.reason)" }
            }
            if dataFns.contains("refusals") || componentId == "refusals" {
                let rows = AuditLog.refusals(auditEvents, botId: botId)
                items = rows.map { "\($0.tool ?? $0.type.rawValue): \($0.reason)" }
            }
            let payload = ComponentPayload(
                id: componentId,
                title: title,
                fields: fields,
                items: items
            )
            return AgentToolCallResult(
                output: "Presented \(componentId).",
                blocks: [.component(payload)]
            )

        case "report_decline":
            let reason = s("reason")
            recordAudit(
                type: .botDeclined,
                botId: botId,
                tool: "report_decline",
                reason: reason.isEmpty ? "declined" : reason,
                allowed: true,
                forwarded: true
            )
            return AgentToolCallResult(
                output: "Recorded the decline.",
                blocks: [.card(lines: [CardLine(k: "declined", v: reason)])]
            )

        case "artifact_create":
            let rawKind = s("type", "kind", "artifact_type")
            guard let kind = ArtifactKind.parse(rawKind) else {
                return AgentToolCallResult(output: ArtifactError.unknownKind(rawKind).localizedDescription)
            }
            do {
                let record = try artifactStore.create(
                    id: s("id", "identifier", "slug"),
                    title: s("title", "name"),
                    kind: kind,
                    language: s("language", "lang"),
                    content: s("content", "body", "text"),
                    botId: botId
                )
                let mirrored = mirrorArtifact(record, botId: botId, path: resolveToolPath(record.fileName))
                showArtifact(record.id)
                return artifactResult(mirrored, verb: "Created")
            } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }

        case "artifact_update":
            do {
                let record = try artifactStore.update(
                    id: s("id", "artifact_id", "title"),
                    oldString: s("old_str", "old_string", "find"),
                    newString: s("new_str", "new_string", "replace")
                )
                let mirrored = mirrorArtifact(record, botId: botId, path: resolveToolPath(record.fileName))
                showArtifact(record.id)
                return artifactResult(mirrored, verb: "Updated")
            } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }

        case "artifact_rewrite":
            do {
                let newTitle = s("title", "name")
                let record = try artifactStore.rewrite(
                    id: s("id", "artifact_id"),
                    content: s("content", "body", "text"),
                    title: newTitle.isEmpty ? nil : newTitle
                )
                let mirrored = mirrorArtifact(record, botId: botId, path: resolveToolPath(record.fileName))
                showArtifact(record.id)
                return artifactResult(mirrored, verb: "Rewrote")
            } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }

        case "artifact_list":
            reloadArtifacts()
            if artifacts.isEmpty {
                return AgentToolCallResult(output: "No artifacts yet. artifact_create makes one.")
            }
            let text = artifacts
                .map { "• \($0.id) — \($0.title) (\($0.summary))" }
                .joined(separator: "\n")
            return AgentToolCallResult(
                output: text,
                blocks: [.card(lines: artifacts.prefix(8).map { CardLine(k: $0.title, v: $0.id) })]
            )

        case "artifact_read":
            let id = s("id", "artifact_id", "title")
            guard let record = artifactStore.load(id: id) else {
                return AgentToolCallResult(output: ArtifactError.notFound(id).localizedDescription)
            }
            // The content is the point of the call, so it goes in the output
            // verbatim — the card just names what was read.
            return AgentToolCallResult(
                output: record.content,
                blocks: [.card(lines: [
                    CardLine(k: "read", v: record.title),
                    CardLine(k: "id", v: record.id),
                    CardLine(k: "type", v: record.summary),
                ])]
            )

        case "artifact_delete":
            let id = s("id", "artifact_id", "title")
            do {
                let removed = try artifactStore.delete(id: id)
                reloadArtifacts()
                if activeArtifactId == removed.id {
                    activeArtifactId = artifacts.first?.id
                    artifactVersionIndex = nil
                    if activeArtifactId == nil, panel == .artifact { panel = nil }
                }
                artifactRevision += 1
                return AgentToolCallResult(
                    output: "Deleted artifact \(removed.title) (\(removed.id)).",
                    blocks: [.artifact(
                        id: removed.id,
                        title: removed.title,
                        kind: removed.kind,
                        summary: removed.summary,
                        deleted: true
                    )]
                )
            } catch {
                return AgentToolCallResult(output: error.localizedDescription)
            }

        case "canvas_list":
            reloadCanvases()
            if canvases.isEmpty {
                return AgentToolCallResult(output: "No canvases yet. canvas_save or canvas_place_image to create one.")
            }
            let text = canvases.map { "• \($0.title) (\($0.id))" }.joined(separator: "\n")
            return AgentToolCallResult(
                output: text,
                blocks: [.card(lines: canvases.prefix(8).map { CardLine(k: $0.title, v: $0.id) })]
            )

        case "canvas_open":
            let id = s("id", "title", "name")
            openCanvas(id: id.isEmpty ? nil : id, placingScreenshotFrom: botId)
            let opened = activeCanvas()
            let placed = opened.map { $0.images.isEmpty ? "No screenshot to place." : "Showing \($0.images.count) image(s)." } ?? ""
            return AgentToolCallResult(
                output: [opened.map { "Opened canvas \($0.title) (\($0.id))." }, placed]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                blocks: [.card(lines: [
                    CardLine(k: "canvas", v: opened?.title ?? "open"),
                    CardLine(k: "id", v: opened?.id ?? ""),
                    CardLine(k: "images", v: "\(opened?.images.count ?? 0)"),
                ])]
            )

        case "canvas_save":
            let id = s("id")
            let title = s("title", "name")
            var record = id.isEmpty ? nil : canvasBoard.load(id: id)
            if record == nil, !title.isEmpty {
                record = canvasBoard.load(id: title)
            }
            if var existing = record {
                if !title.isEmpty { existing.title = title }
                let saved = saveCanvas(existing)
                return AgentToolCallResult(
                    output: saved.map { "Saved canvas \($0.title) (\($0.id))." } ?? "Save failed.",
                    blocks: [.card(lines: [CardLine(k: "canvas", v: saved?.title ?? title), CardLine(k: "id", v: saved?.id ?? "")])]
                )
            }
            let created = createCanvas(title: title)
            return AgentToolCallResult(
                output: "Saved canvas \(created.title) (\(created.id)).",
                blocks: [.card(lines: [CardLine(k: "canvas", v: created.title), CardLine(k: "id", v: created.id)])]
            )

        case "canvas_delete":
            let id = s("id", "title", "name")
            guard let match = canvasBoard.load(id: id) else {
                return AgentToolCallResult(output: "No canvas named \(id).")
            }
            deleteCanvas(id: match.id)
            return AgentToolCallResult(
                output: "Deleted canvas \(match.title).",
                blocks: [.card(lines: [CardLine(k: "deleted", v: match.title)])]
            )

        case "canvas_place_image":
            let id = s("id")
            let title = s("title", "name")
            let path = s("path", "file")
            guard let jpeg = canvasImageData(botId: botId, path: path) else {
                return AgentToolCallResult(output: "No image to place. Take a computer_screenshot first, or pass path to a JPEG/PNG in the bot home.")
            }
            let name = title.isEmpty ? (id.isEmpty ? "Screenshot" : id) : title
            do {
                let saved = try canvasBoard.placeImage(
                    canvasId: id.isEmpty ? nil : canvasBoard.load(id: id)?.id,
                    title: name,
                    jpeg: jpeg
                )
                reloadCanvases()
                activeCanvasId = saved.id
                canvasOpen = true
                canvasRevision += 1
                return AgentToolCallResult(
                    output: "Placed image on canvas \(saved.title) (\(saved.id)).",
                    blocks: [.card(lines: [
                        CardLine(k: "canvas", v: saved.title),
                        CardLine(k: "images", v: "\(saved.images.count)"),
                    ])]
                )
            } catch {
                return AgentToolCallResult(output: "Could not place image: \(error.localizedDescription)")
            }

        case "read_skill":
            let id = SkillMarkdown.slug(s("id", "name", "skill"))
            guard !id.isEmpty else { return AgentToolCallResult(output: "id is required") }
            guard let skill = skills(for: bot).first(where: { $0.id == id || $0.name.lowercased() == id }) else {
                let available = skills(for: bot).map(\.id).joined(separator: ", ")
                return AgentToolCallResult(output: "Unknown or disabled skill \(id). Available: \(available.isEmpty ? "none" : available)")
            }
            return AgentToolCallResult(
                output: skill.body,
                blocks: [.card(lines: [CardLine(k: "skill", v: skill.id)])]
            )

        case "capabilities_discover":
            let query = s("query", "q")
            guard !query.isEmpty else { return AgentToolCallResult(output: "query is required") }
            let topK = Int(s("top_k", "limit")) ?? 8
            let catalog = CapabilitySearch.entries(
                skills: skills(for: bot),
                builtins: AgentToolCatalog.builtin.filter { bot.isToolEnabled($0.id) },
                mcpAdvertised: advertisedMcpTools(for: bot),
                promotedMcp: promotedMcpTools(for: bot)
            )
            let hits = CapabilitySearch.search(query, in: catalog, topK: topK)
            return AgentToolCallResult(
                output: CapabilitySearch.formatDiscover(hits),
                blocks: [.card(lines: hits.prefix(8).map {
                    CardLine(k: $0.entry.kind.rawValue, v: $0.entry.id)
                })]
            )

        case "capabilities_load":
            let rawIds = s("ids", "id")
            guard !rawIds.isEmpty else { return AgentToolCallResult(output: "ids is required") }
            let ids = rawIds
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { SkillMarkdown.slug(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
                .filter { !$0.isEmpty }
            var notes: [String] = []
            var skillBodies: [(id: String, body: String)] = []
            var promoted: [McpPromotedTool] = []
            let botSkills = skills(for: bot)
            for id in ids {
                if let skill = botSkills.first(where: { $0.id == id || $0.name.lowercased() == id }) {
                    skillBodies.append((skill.id, skill.body))
                    notes.append("loaded skill \(skill.id)")
                    continue
                }
                if let existing = mcpPromotedTools[id] {
                    if McpToolGate.isToolEnabled(
                        enabledIds: bot.enabledTools,
                        serverId: existing.serverId,
                        toolName: existing.chatName,
                        advertised: mcpToolNames(for: existing.serverId)
                    ) {
                        promoted.append(existing)
                        notes.append("activated MCP \(id)")
                    } else {
                        notes.append("MCP \(id) is turned off for this bot")
                    }
                    continue
                }
                // Match advertised MCP names and promote a thin stub.
                var found = false
                for (serverId, names) in mcpAdvertisedTools {
                    if names.contains(where: { $0 == id || SkillMarkdown.slug($0) == id }) {
                        guard McpToolGate.isToolEnabled(
                            enabledIds: bot.enabledTools,
                            serverId: serverId,
                            toolName: id,
                            advertised: names
                        ) else {
                            notes.append("MCP \(id) is turned off for this bot")
                            found = true
                            break
                        }
                        let tool = McpPromotedTool(
                            chatName: id,
                            serverId: serverId,
                            executeTool: id,
                            description: "MCP tool \(id)"
                        )
                        promoted.append(tool)
                        notes.append("promoted MCP \(id) on \(serverId)")
                        found = true
                        break
                    }
                }
                if !found {
                    if AgentToolCatalog.builtin.contains(where: { $0.id == id }) {
                        notes.append("builtin \(id) is already in the tool schema when enabled")
                    } else {
                        notes.append("unknown id \(id)")
                    }
                }
            }
            if !promoted.isEmpty {
                mcpPromotedTools = McpCatalogPromote.merge(existing: mcpPromotedTools, adding: promoted)
            }
            return AgentToolCallResult(
                output: notes.isEmpty ? "Nothing loaded." : notes.joined(separator: "\n"),
                blocks: [.card(lines: notes.prefix(8).map { CardLine(k: "load", v: $0) })],
                promotedMcpTools: promoted,
                loadedSkillBodies: skillBodies
            )

        case "todo":
            return await AgentSessionTools.handleTodo(markdown: s("markdown", "list"), threadKey: threadKey(for: botId))

        case "complete":
            return await AgentSessionTools.handleComplete(summary: s("summary", "text"), threadKey: threadKey(for: botId))

        case "clarify":
            return AgentSessionTools.handleClarify(question: s("question", "ask", "text"))

        case "import_skills":
            let path = s("path", "directory")
            guard !path.isEmpty else { return AgentToolCallResult(output: "path is required") }
            do {
                let folder: URL
                if BotHomeStore.isHostPath(path) {
                    if BotHomeStore.isDeniedHostPath(path) { throw BotHomeError.hostDenied }
                    folder = URL(fileURLWithPath: BotHomeStore.expandPath(path))
                } else {
                    folder = try botHome.homeURL(botId: botId).appendingPathComponent(path)
                }
                let imported = try SkillLibrary.importFromDirectory(folder, into: userPersistence.root)
                reloadSkills()
                let names = imported.map(\.id).joined(separator: ", ")
                return AgentToolCallResult(
                    output: imported.isEmpty
                        ? "No SKILL.md files found under \(path)."
                        : "Imported \(imported.count) skill(s): \(names)",
                    blocks: [.card(lines: [
                        CardLine(k: "imported", v: imported.isEmpty ? "none" : names),
                        CardLine(k: "from", v: path),
                    ])]
                )
            } catch {
                return AgentToolCallResult(output: "Import failed: \(error.localizedDescription)")
            }

        case "request_takeover":
            let reason = s("reason")
            if var computer = computers[botId] {
                computer.controlHolder = .user
                computers[botId] = computer
            }
            recordAudit(
                type: .computerHelpRequested,
                botId: botId,
                tool: "request_takeover",
                reason: reason.isEmpty ? "help requested" : reason,
                allowed: true,
                forwarded: true
            )
            return AgentToolCallResult(
                output: "Asked the user to take over the computer.",
                blocks: [.ask(text: "Take over the computer", detail: reason.isEmpty ? nil : reason)],
                pause: .takeover
            )

        case "destination_write":
            let title = s("title")
            let body = s("body", "content")
            let slug = s("destination", "slug", "plugin")
            if let gated = gatedWrite(
                tool: "destination_write",
                detail: title.isEmpty ? slug : title,
                argumentsJSON: argumentsJSON,
                bot: bot,
                approved: approved
            ) {
                return gated
            }
            let target = connections.first(where: { $0.connected && (slug.isEmpty || $0.slug == slug) })
            var record = DestinationRecord(
                slug: target?.slug ?? (slug.isEmpty ? "local" : slug),
                title: title.isEmpty ? "Note" : title,
                body: body
            )
            var remote = "local log"
            if let target {
                do {
                    remote = try await writePlugin(slug: target.slug, title: record.title, body: body)
                    record.remoteId = remote
                } catch {
                    remote = "plugin error: \(error.localizedDescription)"
                }
            }
            try? destinations.append(record)
            return AgentToolCallResult(
                output: "Wrote to \(record.slug) (\(remote)). id=\(record.id)",
                blocks: [.card(lines: [
                    CardLine(k: record.slug, v: remote),
                    CardLine(k: "title", v: record.title),
                ])]
            )

        case "spawn_bot":
            let name = s("name")
            guard !name.isEmpty else { return AgentToolCallResult(output: "name is required") }
            let title = s("title")
            let instructions = s("instructions")
            let firstPrompt = s("prompt")
            let child = createBot(
                name: name,
                title: title,
                description: "",
                instructions: instructions,
                parentBotId: botId
            )
            activeBotId = botId
            if !firstPrompt.isEmpty {
                send(botId: child.id, text: firstPrompt)
            }
            return AgentToolCallResult(
                output: "Created bot \(child.name) (\(child.id)).",
                blocks: [.childBot(botId: child.id, name: child.name, title: child.title, status: .created)]
            )

        case "delete_bot":
            let confirm = s("confirm_name", "name")
            let targetId = s("bot_id", "id")
            let target: Bot? = {
                if !targetId.isEmpty {
                    return bots.first(where: { $0.id == targetId })
                }
                return bots.first(where: { $0.name.caseInsensitiveCompare(confirm) == .orderedSame })
            }()
            guard let target else {
                return AgentToolCallResult(output: "No bot named \(confirm).")
            }
            if target.id == botId {
                return AgentToolCallResult(output: "You cannot delete yourself.")
            }
            if target.parentBotId != botId {
                return AgentToolCallResult(output: "You can only delete bots you spawned.")
            }
            if !confirm.isEmpty, target.name.caseInsensitiveCompare(confirm) != .orderedSame {
                return AgentToolCallResult(output: "confirm_name must match \(target.name).")
            }
            let id = target.id
            let n = target.name
            deleteBot(id)
            return AgentToolCallResult(
                output: "Deleted bot \(n).",
                blocks: [.childBot(botId: id, name: n, title: nil, status: .deleted)]
            )

        case "run_subagent":
            let helperName = s("name").isEmpty ? "helper" : s("name")
            let task = s("task")
            let extra = s("instructions")
            guard !task.isEmpty else { return AgentToolCallResult(output: "task is required") }
            if depth >= 1 {
                return AgentToolCallResult(output: "Nested helpers cannot spawn further helpers. Do the work yourself.")
            }
            let helperId = Ids.new()
            do {
                let nestedTools = AgentToolCatalog.chatTools(
                    enabledIds: bot.enabledTools,
                    mcpServers: mcpServers,
                    includeDelegation: false,
                    skills: skills(for: bot),
                    promotedMcp: Array(mcpPromotedTools.values),
                    mcpAdvertised: mcpAdvertisedTools
                )
                let nested = try await AgentLoop.run(
                    client: client,
                    request: AgentLoopRequest(
                        endpoint: endpoint,
                        botName: helperName,
                        botTitle: "helper",
                        instructions: extra,
                        memory: MemoryIndex.excerpt(
                            memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
                        ),
                        sharedMemory: MemoryIndex.excerpt(sharedMemory),
                        skillCatalog: SkillMarkdown.catalogPrompt(from: skills(for: bot)),
                        homePath: (try? botHome.homeURL(botId: botId).path) ?? "",
                        prompt: task,
                        tools: nestedTools,
                        maxSteps: 16,
                        depth: depth + 1
                    )
                ) { [weak self] nestedName, nestedArgs in
                    guard let self else {
                        return AgentToolCallResult(output: "store released")
                    }
                    return await self.executeAgentTool(
                        name: nestedName,
                        argumentsJSON: nestedArgs,
                        botId: botId,
                        depth: depth + 1,
                        endpoint: endpoint,
                        client: client
                    )
                }
                return AgentToolCallResult(
                    output: nested.text.isEmpty ? "Helper finished." : nested.text,
                    blocks: nested.blocks + [
                        .subagent(
                            agentId: helperId,
                            name: helperName,
                            task: task,
                            status: .completed,
                            progress: nil,
                            result: nested.text
                        ),
                    ]
                )
            } catch {
                return AgentToolCallResult(
                    output: "Helper failed: \(error.localizedDescription)",
                    blocks: [
                        .subagent(
                            agentId: helperId,
                            name: helperName,
                            task: task,
                            status: .failed,
                            progress: nil,
                            result: error.localizedDescription
                        ),
                    ]
                )
            }

        case "mcp_list_tools":
            guard let server = resolveMcpServer(s("server"), bot: bot) else {
                return AgentToolCallResult(output: mcpServerResolveError(requested: s("server"), bot: bot))
            }
            do {
                let listed = try await McpClient.listTools(server: server)
                let harvested = applyMcpList(serverId: server.id, tools: listed)
                let text = McpClient.formatToolList(listed, serverName: server.name)
                var output = text
                if !harvested.isEmpty {
                    output += "\n\nPromoted \(min(harvested.count, McpCatalogPromote.maxPromoted)) catalog tools as first-class ChatTools this session."
                }
                return AgentToolCallResult(
                    output: output,
                    blocks: [.card(lines: [
                        CardLine(k: "mcp", v: server.name),
                        CardLine(k: "tools", v: "\(listed.count)"),
                    ])],
                    promotedMcpTools: harvested
                )
            } catch {
                mcpProbeStatus[server.id] = .failed(error.localizedDescription)
                let command = ([server.command] + server.args).joined(separator: " ")
                var output = "MCP list failed: \(error.localizedDescription) [\(command)]"
                if let hint = McpGatewayCall.recoveryHint(for: output) {
                    output += "\n\(hint)"
                }
                appendRunLog(botId: botId, kind: "mcp", text: output)
                return AgentToolCallResult(output: output)
            }

        case "mcp_call":
            guard let server = resolveMcpServer(s("server"), toolName: s("tool", "name"), bot: bot) else {
                return AgentToolCallResult(output: mcpServerResolveError(
                    requested: s("server"),
                    toolName: s("tool", "name"),
                    bot: bot
                ))
            }
            let toolName = s("tool", "name")
            if let denied = mcpToolDisabledMessage(bot: bot, server: server, toolName: toolName, raw: args) {
                return AgentToolCallResult(output: denied)
            }
            let prompt = s("prompt", "query", "text")
            do {
                if toolName.isEmpty {
                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return AgentToolCallResult(
                            output: "mcp_call needs tool=<name from mcp_list_tools>. Pass server=<one of the enabled MCP names>. Example: server=fast-filesystem tool=write_file."
                        )
                    }
                    let result = try await McpClient.invoke(
                        server: server,
                        prompt: prompt.isEmpty ? argumentsJSON : prompt
                    )
                    let prepared = McpPreparedCall(toolName: result.toolName, arguments: [:])
                    let harvested = rememberHarvest(
                        serverId: server.id,
                        catalogTool: result.toolName,
                        text: result.text
                    )
                    return AgentToolCallResult(
                        output: McpGatewayCall.modelOutput(
                            prepared: prepared,
                            isError: result.isError,
                            text: result.text
                        ),
                        blocks: [.card(lines: McpGatewayCall.cardLines(
                            serverName: server.name,
                            catalogTool: result.toolName,
                            gatewayTool: result.toolName,
                            isError: result.isError,
                            text: result.text
                        ))],
                        promotedMcpTools: harvested
                    )
                }
                var prepared = McpGatewayCall.prepare(
                    server: server,
                    toolName: toolName,
                    raw: args
                )
                if McpGatewayCall.missingCatalogName(prepared) {
                    return AgentToolCallResult(
                        output: McpGatewayCall.missingCatalogNameMessage(),
                        blocks: [.card(lines: [
                            CardLine(k: "mcp", v: server.name),
                            CardLine(k: "tool", v: "toolport_call_tool"),
                            CardLine(k: "status", v: "tool error"),
                            CardLine(k: "out", v: "empty catalog name"),
                        ])]
                    )
                }
                if prepared.arguments.isEmpty, !prompt.isEmpty {
                    prepared.arguments = ["prompt": .string(prompt)]
                }
                var result = try await McpClient.call(
                    server: server,
                    toolName: prepared.toolName,
                    arguments: prepared.arguments
                )
                if McpGatewayCall.failed(isError: result.isError, text: result.text),
                   McpGatewayCall.isTransientFailure(result.text) {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    result = try await McpClient.call(
                        server: server,
                        toolName: prepared.toolName,
                        arguments: prepared.arguments
                    )
                }
                let catalog = McpGatewayCall.catalogToolName(prepared)
                let harvested = McpGatewayCall.failed(isError: result.isError, text: result.text)
                    ? []
                    : rememberHarvest(serverId: server.id, catalogTool: catalog, text: result.text)
                var output = McpGatewayCall.modelOutput(
                    prepared: prepared,
                    isError: result.isError,
                    text: result.text
                )
                if !harvested.isEmpty {
                    output += "\nPromoted \(harvested.count) catalog tool(s) as first-class ChatTools — call them directly next."
                }
                return AgentToolCallResult(
                    output: output,
                    blocks: [.card(lines: McpGatewayCall.cardLines(
                        serverName: server.name,
                        prepared: prepared,
                        isError: result.isError,
                        text: result.text
                    ))],
                    promotedMcpTools: harvested
                )
            } catch {
                let command = ([server.command] + server.args).joined(separator: " ")
                var output = "MCP call failed: \(error.localizedDescription) [\(command)]"
                if let hint = McpGatewayCall.recoveryHint(for: output) {
                    output += "\n\(hint)"
                }
                appendRunLog(botId: botId, kind: "mcp", text: output)
                return AgentToolCallResult(
                    output: output,
                    blocks: [.card(lines: McpGatewayCall.cardLines(
                        serverName: server.name,
                        catalogTool: toolName,
                        gatewayTool: toolName,
                        isError: true,
                        text: output
                    ))]
                )
            }

        case "computer_screenshot":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            _ = await prepareComputerSurface(botId: botId, bot: bot)
            guard let snap = await computerRuntime?.snapshot(botId: botId) else {
                return AgentToolCallResult(output: "No computer surface is attached. Enable Screen Recording (This Mac) or open the in-app browser.")
            }
            if ScreenshotQuality.isBlankJPEG(snap.jpeg) {
                return AgentToolCallResult(
                    output: "Screenshot capture returned a blank image. For This Mac: grant Screen Recording to GrizzyBot and open the computer overlay once. For in-app browser: open a URL with computer_open, then screenshot again.",
                    blocks: [.card(lines: [CardLine(k: "screen", v: "blank")])]
                )
            }
            let path = ".computer/screen.jpg"
            if let url = try? botHome.homeURL(botId: botId).appendingPathComponent(path) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? snap.jpeg.write(to: url)
            }
            var output = "Screenshot \(snap.width)x\(snap.height) at \(snap.url). Saved \(path). Click (x,y) uses this image’s pixel space (0,0 is top-left)."
            if !snap.outline.isEmpty {
                output += "\nTargets:\n\(snap.outline)"
            }
            if var computer = computers[botId] {
                computer.lastOutline = snap.outline
                computer.lastPageURL = snap.url
                computer.screenAvailable = true
                computers[botId] = computer
            }
            if canvasOpen {
                _ = placeActiveScreenshot(botId: botId)
            }
            return AgentToolCallResult(
                output: output,
                blocks: [.card(lines: [
                    CardLine(k: "screen", v: "\(snap.width)×\(snap.height)"),
                    CardLine(k: "url", v: snap.url),
                    CardLine(k: "targets", v: snap.outline.isEmpty ? "none" : "listed"),
                ])],
                imageJPEGBase64: snap.jpeg.base64EncodedString()
            )

        case "computer_open":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            let url = s("url")
            guard !url.isEmpty else { return AgentToolCallResult(output: "url is required") }
            _ = await prepareComputerSurface(botId: botId, bot: bot)
            let action = await computerRuntime?.send(ComputerInput(kind: .open, text: url), botId: botId)
            if var computer = computers[botId] {
                computer.state = .running
                computer.screenAvailable = true
                computer.lastPageURL = url
                computers[botId] = computer
            }
            return AgentToolCallResult(
                output: action?.output ?? "Opened \(url).",
                blocks: [.computer(state: "running", text: url)]
            )

        case "computer_click":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            let x = Double(s("x")) ?? 0
            let y = Double(s("y")) ?? 0
            let button = s("button").lowercased()
            let count = Int(s("count")) ?? 1
            let kind: ComputerInput.Kind
            if button == "right" || button == "secondary" {
                kind = .rightClick
            } else if count >= 2 || s("count").lowercased() == "double" {
                kind = .doubleClick
            } else {
                kind = .click
            }
            let action = await computerRuntime?.send(ComputerInput(kind: kind, x: x, y: y), botId: botId)
            if var computer = computers[botId] {
                computer.lastElement = resolved ?? ComputerOutline.hit(
                    outline: computer.lastOutline,
                    x: x,
                    y: y
                )
                computers[botId] = computer
            }
            return AgentToolCallResult(
                output: action?.output ?? "Clicked (\(Int(x)), \(Int(y))).",
                blocks: [.card(lines: [
                    CardLine(k: "click", v: "(\(Int(x)), \(Int(y)))"),
                    CardLine(k: "hit", v: action?.hit?.summary ?? ""),
                ])]
            )

        case "computer_scroll":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            let x = Double(s("x")) ?? 0
            let y = Double(s("y")) ?? 0
            let delta = s("delta", "amount", "dy")
            let action = await computerRuntime?.send(
                ComputerInput(kind: .scroll, x: x, y: y, text: delta.isEmpty ? "120" : delta),
                botId: botId
            )
            return AgentToolCallResult(output: action?.output ?? "Scrolled at (\(Int(x)), \(Int(y))).")

        case "computer_type":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            let text = s("text")
            let action = await computerRuntime?.send(ComputerInput(kind: .type, text: text), botId: botId)
            return AgentToolCallResult(output: action?.output ?? "Typed \(text.count) characters.")

        case "computer_key":
            if let blocked = computerBlockedIfHeadless(bot: bot) { return blocked }
            let key = s("key")
            guard !key.isEmpty else { return AgentToolCallResult(output: "key is required") }
            let action = await computerRuntime?.send(ComputerInput(kind: .key, text: key), botId: botId)
            return AgentToolCallResult(output: action?.output ?? "Pressed \(key).")

        case "plugin_call":
            let rawSlug = s("slug").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if rawSlug.isEmpty {
                return AgentToolCallResult(output: "plugin_call needs a slug (e.g. gmail, google-calendar, or x).")
            }
            let slug = resolvePluginSlug(rawSlug)
            if slug == "composio_connect" || slug == "composio" || slug == "composio_api" {
                let hasKey = pluginsUseOAuth
                return AgentToolCallResult(
                    output: hasKey
                        ? "Composio Connect is a Settings key (already saved), not a plugin. Open Plugins and Connect Gmail / Google Calendar, then call plugin_call with slug gmail or google-calendar."
                        : "Composio Connect is a Settings → Connections → Keys field, not a plugin. Save a Composio Connect key there, then Connect Gmail from Plugins."
                )
            }
            if !connections.contains(where: { $0.slug == slug && $0.connected }) {
                await syncComposioConnection(slug: slug)
            }
            guard connections.contains(where: { $0.slug == slug && $0.connected }) else {
                let hint: String
                if pluginsUseOAuth {
                    let label = slug == "x" ? "X (Twitter)" : slug
                    hint = " Open Plugins → \(label) → Connect (browser OAuth via Composio). For X, Composio also needs an Auth Config with your X Developer keys. Then try again."
                } else {
                    hint = " Save a Composio Connect key in Settings → Connections → Keys, then Connect \(slug) from Plugins."
                }
                return AgentToolCallResult(
                    output: "Plugin \(rawSlug) is not connected.\(hint)",
                    blocks: [.card(lines: [CardLine(k: "plugin_call", v: "Plugin \(rawSlug) is not connected.")])]
                )
            }
            let action = s("action").lowercased()
            let isDelete = action == "delete" || action == "remove" || action == "cancel"
            let isWrite = !isDelete && (action.isEmpty || action == "write")
            if isWrite, let gated = gatedWrite(
                tool: "plugin_call",
                detail: "\(slug) \(s("title"))",
                argumentsJSON: argumentsJSON,
                bot: bot,
                approved: approved
            ) {
                return gated
            }
            do {
                let account = s("account", "connected_account", "connected_account_id")
                if !account.isEmpty {
                    storeAccountPreferenceFromTool(slug: slug, account: account)
                }
                if isDelete {
                    if let gated = gatedWrite(
                        tool: "plugin_call",
                        detail: "\(slug) delete \(s("id", "event_id", "eventId", "query", "body"))",
                        argumentsJSON: argumentsJSON,
                        bot: bot,
                        approved: approved
                    ) {
                        return gated
                    }
                    let target = s("id", "event_id", "eventId", "query", "body", "title")
                    let removed = try await deletePlugin(slug: slug, id: target)
                    return AgentToolCallResult(
                        output: "Plugin \(slug) deleted \(removed).",
                        blocks: [.card(lines: [CardLine(k: slug, v: "deleted \(removed)")])]
                    )
                }
                if isWrite {
                    let remote = try await writePlugin(
                        slug: slug,
                        title: s("title"),
                        body: s("body"),
                        account: account.isEmpty ? nil : account
                    )
                    return AgentToolCallResult(
                        output: "Plugin \(slug) wrote \(remote).",
                        blocks: [.card(lines: [
                            CardLine(k: slug, v: ComposioClient.chatSummary(slug: slug, query: s("title"), result: remote, failed: false)),
                        ])]
                    )
                }
                let rawQuery = s("query", "q", "body", "title")
                let query = ComposioClient.normalizedReadQuery(
                    slug: slug,
                    query: rawQuery.isEmpty ? action : rawQuery
                )
                let remote = try await readPlugin(
                    slug: slug,
                    query: query,
                    account: account.isEmpty ? nil : account
                )
                let summary = ComposioClient.chatSummary(slug: slug, query: query, result: remote, failed: false)
                return AgentToolCallResult(
                    output: remote,
                    blocks: [.card(lines: [
                        CardLine(k: slug, v: summary),
                    ])]
                )
            } catch {
                let detail = error.localizedDescription
                let summary = ComposioClient.chatSummary(slug: slug, query: "", result: detail, failed: true)
                return AgentToolCallResult(
                    output: "Plugin failed: \(detail)",
                    blocks: [.card(lines: [CardLine(k: slug, v: summary)])]
                )
            }

        default:
            let enabled = enabledMcpServers(bot: bot)
            let names = enabled.map(\.name).joined(separator: ", ")
            if McpGatewayCall.isMetaTool(name), !enabled.contains(where: { McpGatewayCall.isGateway($0) }) {
                return AgentToolCallResult(
                    output: McpToolRouting.missingGatewayMessage(tool: name, enabled: enabled)
                )
            }
            if names.isEmpty {
                return AgentToolCallResult(output: "Unknown tool: \(name)")
            }
            return AgentToolCallResult(
                output: "Unknown tool: \(name). Available MCP servers: \(names). Call first-class server__tool names from your list, or mcp_call with server=<name> and tool from mcp_list_tools."
            )
        }
    }

    private func enabledMcpServers(bot: Bot) -> [McpServer] {
        mcpServers.filter { bot.isToolEnabled($0.toolId) }
    }

    private func advertisedMcpTools(for bot: Bot) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for server in enabledMcpServers(bot: bot) {
            let names = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[server.id] ?? [])
            let allowed = names.filter {
                McpToolGate.isToolEnabled(
                    enabledIds: bot.enabledTools,
                    serverId: server.id,
                    toolName: $0,
                    advertised: names
                )
            }
            if !allowed.isEmpty {
                out[server.id] = allowed
            }
        }
        return out
    }

    private func promotedMcpTools(for bot: Bot) -> [McpPromotedTool] {
        mcpPromotedTools.values.filter { promo in
            let advertised = mcpToolNames(for: promo.serverId)
            return McpToolGate.isToolEnabled(
                enabledIds: bot.enabledTools,
                serverId: promo.serverId,
                toolName: promo.chatName,
                advertised: advertised
            )
        }
    }

    private func mcpToolDisabledMessage(
        bot: Bot,
        server: McpServer,
        toolName: String,
        raw: [String: JSONValue]
    ) -> String? {
        let prepared = McpGatewayCall.prepare(server: server, toolName: toolName, raw: raw)
        let catalog = McpGatewayCall.catalogToolName(prepared)
        let advertised = mcpToolNames(for: server.id)
        let names = Set([toolName, catalog].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for name in names {
            if !McpToolGate.isToolEnabled(
                enabledIds: bot.enabledTools,
                serverId: server.id,
                toolName: name,
                advertised: advertised
            ) {
                return "MCP tool \(name) is turned off for this bot on \(server.name). Enable it under Tools."
            }
        }
        return nil
    }

    private func resolveMcpServer(_ raw: String, toolName: String = "", bot: Bot) -> McpServer? {
        switch McpToolRouting.resolveServer(
            requested: raw,
            toolName: toolName,
            enabled: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        ) {
        case .resolved(let server):
            return server
        case .failed:
            return nil
        }
    }

    private func mcpServerResolveError(requested: String, toolName: String = "", bot: Bot) -> String {
        switch McpToolRouting.resolveServer(
            requested: requested,
            toolName: toolName,
            enabled: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        ) {
        case .resolved:
            return "Unknown or disabled MCP server '\(requested)'."
        case .failed(let message):
            return message
        }
    }

    private func rememberPromoted(_ tools: [McpPromotedTool], serverId: String) {
        guard !tools.isEmpty else { return }
        mcpPromotedTools = McpCatalogPromote.merge(existing: mcpPromotedTools, adding: tools)
        var advertised = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[serverId] ?? [])
        for tool in tools where !McpCatalogPromote.isDispatcher(tool.executeTool) {
            if !advertised.contains(tool.executeTool) { advertised.append(tool.executeTool) }
        }
        mcpAdvertisedTools[serverId] = McpCatalogPromote.uniqueAdvertisedNames(advertised)
    }

    @discardableResult
    private func applyMcpList(serverId: String, tools: [McpToolInfo]) -> [McpPromotedTool] {
        let names = McpCatalogPromote.uniqueAdvertisedNames(tools.map(\.name))
        mcpAdvertisedTools[serverId] = names
        mcpListedTools[serverId] = tools
        mcpProbeStatus[serverId] = .connected(toolCount: names.count)
        let server = mcpServers.first(where: { $0.id == serverId })
            ?? McpServer(id: serverId, name: serverId)
        let harvested = McpCatalogPromote.fromListed(server: server, tools: tools)
        rememberPromoted(harvested, serverId: serverId)
        optInMcpChildTools(serverId: serverId, names: names)
        save()
        return harvested
    }

    private func optInMcpChildTools(serverId: String, names: [String]) {
        for name in names {
            optInNewTool(McpToolGate.childId(serverId: serverId, toolName: name))
        }
    }

    @discardableResult
    private func rememberHarvest(serverId: String, catalogTool: String, text: String) -> [McpPromotedTool] {
        let harvested = McpCatalogPromote.harvest(
            serverId: serverId,
            catalogTool: catalogTool,
            text: text
        )
        rememberPromoted(harvested, serverId: serverId)
        return harvested
    }

    private func hydratePromotedFromAdvertised(bot: Bot) {
        let stubs = McpCatalogPromote.fromAdvertised(
            servers: enabledMcpServers(bot: bot),
            advertised: advertisedMcpTools(for: bot)
        )
        mcpPromotedTools = McpCatalogPromote.merge(existing: mcpPromotedTools, adding: stubs)
        for serverId in Set(stubs.map(\.serverId)) {
            if let names = mcpAdvertisedTools[serverId] {
                mcpAdvertisedTools[serverId] = McpCatalogPromote.uniqueAdvertisedNames(names)
            }
        }
    }

    /// Prefetch Toolport catalog matches from the user prompt so Gmail/MacUse tools are first-class on step 1.
    private func warmMcpCatalog(bot: Bot, prompt: String) async {
        let enabled = enabledMcpServers(bot: bot)
        let queries = McpCatalogPromote.warmQueries(from: prompt)
        if let gateway = enabled.first(where: { McpGatewayCall.isGateway($0) }) {
            for item in queries {
                var args: [String: JSONValue] = ["query": .string(item.query)]
                if let filter = item.server {
                    args["server"] = .string(filter)
                }
                let prepared = McpGatewayCall.prepare(
                    server: gateway,
                    toolName: "toolport_search_tools",
                    raw: ["tool": .string("toolport_search_tools"), "arguments": .object(args)]
                )
                guard let result = try? await McpClient.call(
                    server: gateway,
                    toolName: prepared.toolName,
                    arguments: prepared.arguments
                ), !McpGatewayCall.failed(isError: result.isError, text: result.text)
                else { continue }
                rememberHarvest(serverId: gateway.id, catalogTool: "toolport_search_tools", text: result.text)
            }
        }

        let lower = prompt.lowercased()
        let wantsMail = lower.contains("gmail") || lower.contains("email") || lower.contains("inbox")
            || lower.contains("macuse")
        guard wantsMail else { return }
        let server = enabled.first { $0.name.lowercased().contains("macuse") }
            ?? enabled.first(where: { McpGatewayCall.isGateway($0) })
        guard let server else { return }
        let mailNames: [JSONValue] = [
            .string("mail_list_accounts"),
            .string("mail_list_mailboxes"),
            .string("mail_search_messages"),
            .string("mail_get_messages"),
            .string("mail_get_message"),
        ]
        let defsPrepared = McpGatewayCall.prepare(
            server: server,
            toolName: "macuse__get_tool_definitions",
            raw: [
                "tool": .string("macuse__get_tool_definitions"),
                "arguments": .object(["names": .array(mailNames)]),
            ]
        )
        guard let defs = try? await McpClient.call(
            server: server,
            toolName: defsPrepared.toolName,
            arguments: defsPrepared.arguments
        ), !McpGatewayCall.failed(isError: defs.isError, text: defs.text)
        else { return }
        rememberHarvest(
            serverId: server.id,
            catalogTool: "macuse__get_tool_definitions",
            text: defs.text
        )
    }

    private func applyAction(
        _ action: ScriptedAction?,
        botId: String,
        blocks: inout [MessageBlock],
        thread: inout ThreadData,
        runId: String
    ) async {
        guard let action else { return }
        switch action {
        case .spawnBot(let name, let title):
            let child = createBot(
                name: name,
                title: title,
                description: "",
                instructions: "",
                parentBotId: botId
            )
            // createBot selects the child; restore parent as active for the chat context
            activeBotId = botId
            blocks.append(.childBot(botId: child.id, name: child.name, title: child.title, status: .created))

        case .deleteBot(let name):
            if let target = bots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let id = target.id
                let n = target.name
                deleteBot(id)
                blocks.append(.childBot(botId: id, name: n, title: nil, status: .deleted))
            }

        case .subagent(let task):
            blocks.append(
                .subagent(
                    agentId: Ids.new(),
                    name: "helper",
                    task: task,
                    status: .running,
                    progress: "working…",
                    result: nil
                )
            )

        case .takeover:
            if var computer = computers[botId] {
                computer.controlHolder = .user
                computers[botId] = computer
            }

        case .remember(let text):
            upsertMemory(botId: botId, text: text)

        case .writeFile(let path, let content):
            writeBotFile(botId: botId, path: path, content: content)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(.card(lines: [
                CardLine(k: "wrote", v: path),
                CardLine(k: "preview", v: String(trimmed.prefix(240))),
            ]))

        case .readFile(let path):
            do {
                let content = try botHome.read(botId: botId, path: path)
                blocks.append(.card(lines: [
                    CardLine(k: "read", v: path),
                    CardLine(k: "content", v: String(content.prefix(800))),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "read failed", v: error.localizedDescription)]))
            }

        case .editFile(let path, let content, let append):
            do {
                try botHome.edit(
                    botId: botId,
                    path: path,
                    content: content,
                    mode: append ? .append : .replace
                )
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: append ? "appended" : "edited", v: path),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "edit failed", v: error.localizedDescription)]))
            }

        case .moveFile(let from, let to):
            do {
                try botHome.move(botId: botId, from: from, to: to)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: "moved", v: "\(from) → \(to)"),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "move failed", v: error.localizedDescription)]))
            }

        case .deleteFile(let path):
            do {
                try botHome.delete(botId: botId, path: path)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [CardLine(k: "deleted", v: path)]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "delete failed", v: error.localizedDescription)]))
            }

        case .listFiles(let directory):
            do {
                let entries = try botHome.list(botId: botId, directory: directory)
                if entries.isEmpty {
                    blocks.append(.card(lines: [CardLine(k: "home", v: "(empty)")]))
                } else {
                    let lines = entries.prefix(20).map { entry in
                        CardLine(k: entry.isDirectory ? "dir" : "file", v: entry.path)
                    }
                    blocks.append(.card(lines: Array(lines)))
                }
            } catch {
                blocks.append(.card(lines: [CardLine(k: "list failed", v: error.localizedDescription)]))
            }

        case .webSearch(let query):
            do {
                let results = try await WebSearch.search(query: query, limit: 5, braveKey: appConfig.braveSearchKey)
                if results.isEmpty {
                    blocks.append(.card(lines: [
                        CardLine(k: "search", v: query),
                        CardLine(k: "results", v: "no results"),
                    ]))
                } else {
                    var lines = [CardLine(k: "search", v: query)]
                    for (idx, item) in results.enumerated() {
                        lines.append(CardLine(k: "\(idx + 1). \(item.title)", v: item.snippet.isEmpty ? item.url : item.snippet))
                    }
                    blocks.append(.card(lines: lines))
                    blocks.append(.text(results.map { "• **\($0.title)** — \($0.snippet)\n  \($0.url)" }.joined(separator: "\n\n")))
                }
            } catch {
                blocks.append(.card(lines: [
                    CardLine(k: "search failed", v: error.localizedDescription),
                ]))
            }

        case .destinationWrite(let title, let body):
            let record = DestinationRecord(slug: "local", title: title, body: body)
            try? destinations.append(record)
            blocks.append(.card(lines: [
                CardLine(k: title, v: "recorded"),
                CardLine(k: "id", v: record.id),
            ]))

        case .customTool(let id, let name):
            if let tool = customTools.first(where: { $0.id == id }) {
                blocks.append(.card(lines: [
                    CardLine(k: "tool", v: name),
                    CardLine(k: "status", v: "completed"),
                ]))
                _ = tool
            } else {
                blocks.append(.card(lines: [CardLine(k: "tool", v: name), CardLine(k: "status", v: "completed")]))
            }

        case .mcpServer(let id, let name, let prompt):
            if let server = mcpServers.first(where: { $0.id == id }) {
                do {
                    let result = try await McpClient.invoke(server: server, prompt: prompt)
                    var lines = [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "tool", v: result.toolName),
                        CardLine(k: "status", v: result.isError ? "tool error" : "ok"),
                    ]
                    switch server.transport {
                    case .stdio:
                        lines.insert(CardLine(k: "command", v: server.summaryLine), at: 2)
                    case .http, .sse:
                        lines.insert(CardLine(k: "url", v: server.summaryLine), at: 2)
                    }
                    blocks.append(.card(lines: lines))
                    let body = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        blocks.append(.text(String(body.prefix(4000))))
                    }
                } catch {
                    blocks.append(.card(lines: [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "status", v: "failed"),
                        CardLine(k: "error", v: error.localizedDescription),
                    ]))
                }
            } else {
                blocks.append(.card(lines: [
                    CardLine(k: "mcp", v: name),
                    CardLine(k: "status", v: "missing"),
                ]))
            }
        }
    }

    private func writeBotFile(botId: String, path: String, content: String) {
        do {
            try botHome.write(botId: botId, path: path, content: content)
        } catch {
            // Fall back to workspace mirror only.
        }
        upsertFile(path: path, content: content)
        refreshFilesMirror(botId: botId)
        ingestMemoryFileIfNeeded(botId: botId, path: path)
    }

    private func refreshFilesMirror(botId: String) {
        if let listed = try? botHome.allFilesFlat(botId: botId) {
            files = listed
        }
    }

    public func botHomeEntries(botId: String) -> [BotHomeStore.Entry] {
        (try? botHome.list(botId: botId)) ?? []
    }

    public func readBotHomeFile(botId: String, path: String) -> String? {
        try? botHome.read(botId: botId, path: path)
    }

    private func threadKey(for botId: String) -> String {
        if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
            return taskId
        }
        return botId
    }

    private func completeSubagent(botId: String, threadKey: String, runId: String, messageId: String, task: String) async {
        await sleep(1.5)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey] else { return }
        guard let msgIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var blocks = thread.messages[msgIdx].blocks
        for i in blocks.indices {
            if case .subagent(let agentId, let name, let t, _, _, _) = blocks[i] {
                blocks[i] = .subagent(
                    agentId: agentId,
                    name: name,
                    task: t,
                    status: .completed,
                    progress: nil,
                    result: ScriptedRuntime.subagentResult(for: task)
                )
            }
        }
        thread.messages[msgIdx].blocks = blocks
        thread.run?.status = .completed
        thread.run?.completedAt = .now
        threads[threadKey] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        runTasks.removeValue(forKey: runId)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    private func finishCancelled(botId: String, threadKey: String? = nil, runId: String) {
        let key = threadKey ?? self.threadKey(for: botId)
        guard var thread = threads[key], thread.run?.id == runId else { return }
        thread.messages.removeAll { msg in
            msg.runId == runId && msg.blocks.contains { if case .progress = $0 { return true }; return false }
        }
        thread.run?.status = .cancelled
        thread.run?.completedAt = .now
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        runTasks.removeValue(forKey: runId)
        save()
        finishRoutineIfNeeded(botId: botId, threadKey: key, status: .cancelled, error: "cancelled")
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    private func finishRoutineIfNeeded(
        botId: String,
        threadKey: String,
        status: RunStatus?,
        error: String?
    ) {
        guard let run = threads[threadKey]?.run, run.trigger == "routine",
              let routineId = run.routineId,
              let idx = routines[botId]?.firstIndex(where: { $0.id == routineId })
        else { return }
        let cron = routines[botId]?[idx].cron ?? ""
        switch status {
        case .waitingInput, .waitingTakeover:
            routines[botId]?[idx].inProgress = false
            routines[botId]?[idx].nextRunAt = Cron.nextDate(cron, from: .now)
            save()
        case .completed:
            routines[botId]?[idx].inProgress = false
            routines[botId]?[idx].failCount = 0
            routines[botId]?[idx].lastError = nil
            routines[botId]?[idx].nextRunAt = Cron.nextDate(cron, from: .now)
            save()
        case .failed, .cancelled:
            let fails = (routines[botId]?[idx].failCount ?? 0) + 1
            routines[botId]?[idx].inProgress = false
            routines[botId]?[idx].failCount = fails
            routines[botId]?[idx].lastError = error
            routines[botId]?[idx].nextRunAt = Cron.backoffDate(failCount: fails, from: .now)
            save()
        case .running, .queued, .leased, .none:
            break
        }
    }

    public func stopRun(botId: String) {
        let key = threadKey(for: botId)
        guard let runId = threads[key]?.run?.id else { return }
        runTasks[runId]?.cancel()
        finishCancelled(botId: botId, threadKey: key, runId: runId)
    }

    public func answerAsk(botId: String, answer: String = "approved") {
        guard var thread = threads[botId] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text("done — sent.")]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[botId] = thread
        _ = answer
        save()
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    private func upsertMemory(botId: String, text: String) {
        _ = rememberFact(botId: botId, text: text, shared: false)
    }

    private func upsertSharedMemory(text: String) {
        _ = rememberFact(botId: "", text: text, shared: true)
    }

    public func botMemory(botId: String) -> String {
        memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
    }

    public func setBotMemory(botId: String, text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MemoryLedger.botTemplate
            : text
        replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: content)
        try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: content)
        save()
    }

    @discardableResult
    private func rememberFact(botId: String, text: String, shared: Bool, pin: Bool = false) -> MemoryWriteResult {
        let title = shared ? MemoryLedger.sharedTitle : MemoryLedger.botTitle
        let current = shared ? sharedMemory : botMemory(botId: botId)
        let seed = MemoryLedger.isSparse(current) ? MemoryLedger.template(shared: shared) : current
        let written = MemoryLedger.upsert(content: seed, fact: text, title: title, pin: pin)
        guard written.result != .rejectedSecret, written.result != .empty else { return written.result }
        if shared {
            replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: written.text)
            MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: written.text)
        } else {
            replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: written.text)
            try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: written.text)
        }
        save()
        return written.result
    }

    @discardableResult
    private func forgetFacts(botId: String, query: String, shared: Bool) -> [String] {
        let current = shared ? sharedMemory : botMemory(botId: botId)
        let result = MemoryLedger.forget(content: current, query: query)
        guard !result.removed.isEmpty else { return [] }
        if shared {
            replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: result.text)
            MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: result.text)
        } else {
            replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: result.text)
            try? botHome.write(botId: botId, path: MemoryFiles.botFileName, content: result.text)
        }
        save()
        return result.removed
    }

    private func hydrateMemoryFiles() {
        let sharedURL = MemoryFiles.sharedURL(root: userPersistence.root)
        let jsonShared = memory.first(where: { $0.scope == "workspace" && $0.path == MemoryFiles.sharedFileName })?.content ?? ""
        let diskShared = MemoryFiles.read(sharedURL) ?? ""
        let sharedText: String
        if !MemoryLedger.isSparse(diskShared) {
            sharedText = diskShared
        } else if !MemoryLedger.isSparse(jsonShared) {
            sharedText = jsonShared
        } else {
            sharedText = MemoryLedger.sharedTemplate
        }
        replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: sharedText)
        MemoryFiles.write(sharedURL, content: sharedText)

        for bot in bots {
            let json = memory.first(where: { $0.botId == bot.id && $0.path == MemoryFiles.botFileName })?.content ?? ""
            let disk = (try? botHome.read(botId: bot.id, path: MemoryFiles.botFileName)) ?? ""
            let text: String
            if !MemoryLedger.isSparse(disk) {
                text = disk
            } else if !MemoryLedger.isSparse(json) {
                text = json
            } else {
                text = MemoryLedger.botTemplate
            }
            replaceMemoryDocument(scope: "bot", botId: bot.id, path: MemoryFiles.botFileName, content: text)
            try? botHome.write(botId: bot.id, path: MemoryFiles.botFileName, content: text)
        }
    }

    private func persistMemoryFiles() {
        let shared = sharedMemory.isEmpty ? MemoryLedger.sharedTemplate : sharedMemory
        MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: shared)
        for bot in bots {
            let text = botMemory(botId: bot.id)
            try? botHome.write(
                botId: bot.id,
                path: MemoryFiles.botFileName,
                content: text.isEmpty ? MemoryLedger.botTemplate : text
            )
        }
    }

    private func ingestMemoryFileIfNeeded(botId: String, path: String) {
        guard URL(fileURLWithPath: path).lastPathComponent == MemoryFiles.botFileName else { return }
        let text = (try? botHome.read(botId: botId, path: MemoryFiles.botFileName)) ?? MemoryLedger.botTemplate
        replaceMemoryDocument(scope: "bot", botId: botId, path: MemoryFiles.botFileName, content: text)
    }

    private func replaceMemoryDocument(scope: String, botId: String?, path: String, content: String) {
        let idx: Int?
        if path == MemoryFiles.sharedFileName {
            idx = memory.firstIndex(where: { $0.scope == "workspace" && $0.path == path })
        } else {
            idx = memory.firstIndex(where: { $0.botId == botId && $0.path == path })
        }
        if let idx {
            memory[idx].content = content
            memory[idx].revision += 1
            memory[idx].updatedAt = .now
            if memory[idx].scope.isEmpty { memory[idx].scope = scope }
            if memory[idx].botId == nil { memory[idx].botId = botId }
        } else {
            memory.append(
                MemoryDocument(
                    id: Ids.new(),
                    scope: scope,
                    botId: botId,
                    path: path,
                    content: content
                )
            )
        }
    }

    public var sharedMemory: String {
        memory.first(where: { $0.scope == "workspace" && $0.path == "SHARED.md" })?.content ?? ""
    }

    public func setSharedMemory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.isEmpty ? MemoryLedger.sharedTemplate : text
        replaceMemoryDocument(scope: "workspace", botId: nil, path: MemoryFiles.sharedFileName, content: content)
        MemoryFiles.write(MemoryFiles.sharedURL(root: userPersistence.root), content: content)
        save()
    }

    private func skills(for bot: Bot) -> [AgentSkill] {
        skills.filter { bot.enabledSkills.contains($0.id) }
    }

    /// Skills enabled for a bot (composer `/` autocomplete).
    public func enabledSkills(for botId: String) -> [AgentSkill] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        return skills(for: bot)
    }

    public func reloadSkills() {
        skills = SkillLibrary.load(root: userPersistence.root)
    }

    public func setBotSkill(_ botId: String, skillId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setSkill(skillId, enabled: enabled)
        bots[idx].updatedAt = .now
        save()
    }

    public func installUserSkill(id: String, description: String, body: String) throws {
        let skill = AgentSkill(
            id: SkillMarkdown.slug(id),
            name: id,
            description: description,
            body: body,
            source: .user
        )
        try SkillLibrary.saveUserSkill(skill, root: userPersistence.root)
        reloadSkills()
        for i in bots.indices where !bots[i].enabledSkills.contains(skill.id) {
            bots[i].enabledSkills.append(skill.id)
        }
        save()
    }

    public func deleteUserSkill(_ id: String) throws {
        try SkillLibrary.deleteUserSkill(id: id, root: userPersistence.root)
        reloadSkills()
        for i in bots.indices {
            bots[i].enabledSkills.removeAll { $0 == id }
        }
        save()
    }

    private func announceFinished(botId: String, text: String, status: RunStatus?) {
        guard status == .completed else { return }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        onRunFinished?(bot, cleaned)
    }

    private func upsertFile(path: String, content: String) {
        if let idx = files.firstIndex(where: { $0.first == path }) {
            files[idx] = [path, content]
        } else {
            files.append([path, content])
        }
    }

    // MARK: - Computer

    public func openPanel(_ panel: Panel?) {
        self.panel = panel
        if panel == .computer, let botId = activeBotId {
            autoBootIfNeeded(botId: botId)
        }
    }

    public func toggleComputerPanel() {
        if panel == .computer {
            panel = nil
        } else {
            openPanel(.computer)
        }
    }

    /// Mirrors rakazo `openComputer`: boot if needed, take control, open full-window overlay.
    public func openComputerOverlay() {
        guard let botId = activeBotId, let bot = bots.first(where: { $0.id == botId }) else { return }
        let computer = computers[botId]
        let needsTakeover = computer?.controlHolder != .user
        let needsBoot = computer?.state != .running || computer?.screenAvailable != true
        if needsBoot {
            boot(botId: botId, force: true)
        }
        if needsTakeover {
            takeControl(botId: botId)
        }
        computerOpen = true
        heartbeat(botId: botId)
        Task { @MainActor in
            _ = await prepareComputerSurface(botId: botId, bot: bot)
            await computerRuntime?.prepareForDisplay(botId: botId)
        }
    }

    public func closeComputerOverlay() {
        computerOpen = false
    }

    public func reloadCanvases() {
        canvases = canvasBoard.list()
    }

    // MARK: - Artifacts

    public func reloadArtifacts() {
        artifacts = artifactStore.list()
    }

    public func artifact(id: String) -> ArtifactRecord? {
        artifacts.first { $0.id == id } ?? artifactStore.load(id: id)
    }

    public var activeArtifact: ArtifactRecord? {
        activeArtifactId.flatMap { artifact(id: $0) }
    }

    /// Content for the panel: the selected saved version, else the current one.
    public func artifactContent(_ record: ArtifactRecord) -> String {
        guard let index = artifactVersionIndex,
              record.versions.indices.contains(index)
        else { return record.content }
        return record.versions[index].content
    }

    public func openArtifact(id: String) {
        reloadArtifacts()
        guard artifact(id: id) != nil else { return }
        activeArtifactId = id
        artifactVersionIndex = nil
        artifactRevision += 1
        openPanel(.artifact)
    }

    public func toggleArtifactPanel() {
        if panel == .artifact {
            panel = nil
            return
        }
        reloadArtifacts()
        if activeArtifactId == nil || artifact(id: activeArtifactId ?? "") == nil {
            activeArtifactId = artifacts.first?.id
        }
        artifactVersionIndex = nil
        openPanel(.artifact)
    }

    public func showArtifactVersion(_ index: Int?) {
        artifactVersionIndex = index
        artifactRevision += 1
    }

    /// Creates an artifact by hand from the panel. Bots reach the same store
    /// through `artifact_create`; this exists so an artifact is not something
    /// only a bot can start.
    @discardableResult
    public func createArtifact(
        title: String,
        kind: ArtifactKind,
        language: String? = nil,
        content: String? = nil
    ) -> ArtifactRecord? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content ?? kind.starterContent
        guard let record = try? artifactStore.create(
            id: "",
            title: trimmed.isEmpty ? "Untitled" : trimmed,
            kind: kind,
            language: language,
            content: body,
            botId: activeBotId
        ) else { return nil }

        if let bot = activeBot {
            _ = mirrorArtifact(
                record,
                botId: bot.id,
                path: WorkingFolder.resolve(record.fileName, workingFolder: effectiveWorkingFolder(for: bot))
            )
        }
        reloadArtifacts()
        activeArtifactId = record.id
        artifactVersionIndex = nil
        artifactRevision += 1
        return artifact(id: record.id) ?? record
    }

    /// Saves an edit made in the panel as a new version.
    ///
    /// `baseVersionCount` is what the editor opened against. Bots and routines
    /// share this store and can write while the editor is open, so a save that
    /// lands on top of newer work says so — the history keeps every version, but
    /// silently superseding a bot's edit is the kind of thing you only discover
    /// much later.
    @discardableResult
    public func saveArtifactEdit(
        id: String,
        content: String,
        baseVersionCount: Int
    ) -> ArtifactSaveOutcome {
        guard let current = artifactStore.load(id: id) else {
            return .failed(ArtifactError.notFound(id).localizedDescription)
        }
        guard content != current.content else { return .unchanged }

        let arrived = max(0, current.versions.count - baseVersionCount)
        let saved: ArtifactRecord
        do {
            saved = try artifactStore.rewrite(id: id, content: content, title: nil)
        } catch {
            return .failed(error.localizedDescription)
        }

        if let bot = activeBot {
            _ = mirrorArtifact(
                saved,
                botId: bot.id,
                path: WorkingFolder.resolve(saved.fileName, workingFolder: effectiveWorkingFolder(for: bot))
            )
        }
        reloadArtifacts()
        activeArtifactId = saved.id
        artifactVersionIndex = nil
        artifactRevision += 1
        return arrived > 0 ? .savedOverNewerVersions(arrived) : .saved
    }

    public func deleteArtifact(id: String) {
        guard let removed = try? artifactStore.delete(id: id) else { return }
        reloadArtifacts()
        if activeArtifactId == removed.id {
            activeArtifactId = artifacts.first?.id
            artifactVersionIndex = nil
            if activeArtifactId == nil, panel == .artifact { panel = nil }
        }
        artifactRevision += 1
    }

    /// Refreshes the panel after a tool wrote an artifact. Headless routine
    /// ticks stay headless — the artifact is still created and mirrored, it
    /// just does not yank a panel open with nobody watching.
    private func showArtifact(_ id: String) {
        reloadArtifacts()
        activeArtifactId = id
        artifactVersionIndex = nil
        artifactRevision += 1
        if !headlessRoutineTick {
            openPanel(.artifact)
        }
    }

    /// Writes the artifact into the run's working folder (or the bot home when
    /// none is set). A failed mirror is reported but never fails the tool: the
    /// artifact itself is already saved, and losing it to a disk error would be
    /// the worse outcome.
    private func mirrorArtifact(_ record: ArtifactRecord, botId: String, path: String) -> ArtifactMirror {
        do {
            try botHome.writeFlexible(botId: botId, path: path, content: record.content)
            if !BotHomeStore.isHostPath(path) {
                upsertFile(path: path, content: record.content)
                refreshFilesMirror(botId: botId)
            }
            let noted = (try? artifactStore.noteMirror(id: record.id, path: path)) ?? record
            return ArtifactMirror(record: noted, path: path, error: nil)
        } catch {
            return ArtifactMirror(record: record, path: nil, error: error.localizedDescription)
        }
    }

    private func artifactResult(_ mirror: ArtifactMirror, verb: String) -> AgentToolCallResult {
        let record = mirror.record
        var lines = [
            CardLine(k: verb.lowercased(), v: record.title),
            CardLine(k: "id", v: record.id),
            CardLine(k: "type", v: record.summary),
        ]
        var output = "\(verb) artifact \(record.title) (\(record.id)) — \(record.summary)."
        if let path = mirror.path {
            lines.append(CardLine(k: "file", v: path))
            output += " Mirrored to \(path)."
        }
        if let error = mirror.error {
            lines.append(CardLine(k: "file", v: "not mirrored: \(error)"))
            output += " The artifact saved, but writing the file copy failed: \(error)."
        }
        return AgentToolCallResult(
            output: output,
            blocks: [
                .artifact(
                    id: record.id,
                    title: record.title,
                    kind: record.kind,
                    summary: record.summary,
                    deleted: false
                ),
                .card(lines: lines),
            ]
        )
    }

    public func toggleCanvasPanel() {
        if panel == .canvas {
            panel = nil
        } else {
            reloadCanvases()
            openPanel(.canvas)
        }
    }

    public func openCanvas(id: String?, placingScreenshotFrom botId: String? = nil) {
        reloadCanvases()
        let screenshotBot = botId ?? activeBotId
        let hasShot = screenshotBot.map { canvasImageData(botId: $0, path: "") != nil } ?? false
        if let id, let match = canvasBoard.load(id: id) {
            activeCanvasId = match.id
        } else if hasShot {
            if let empty = canvases.first(where: { $0.images.isEmpty }) {
                activeCanvasId = empty.id
            } else {
                activeCanvasId = createCanvas(title: "Screenshot").id
            }
        } else if let first = canvases.first {
            activeCanvasId = first.id
        } else {
            activeCanvasId = createCanvas(title: "Untitled").id
        }
        if hasShot, let screenshotBot, let board = activeCanvas(), board.images.isEmpty {
            _ = placeActiveScreenshot(botId: screenshotBot)
        }
        canvasOpen = true
        if panel != .canvas {
            openPanel(.canvas)
        }
    }

    public func closeCanvasOverlay() {
        canvasOpen = false
    }

    @discardableResult
    public func createCanvas(title: String) -> CanvasRecord {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CanvasRecord(title: name.isEmpty ? "Untitled" : name)
        let saved = (try? canvasBoard.save(record)) ?? record
        reloadCanvases()
        activeCanvasId = saved.id
        canvasRevision += 1
        return saved
    }

    @discardableResult
    public func saveCanvas(_ record: CanvasRecord) -> CanvasRecord? {
        let saved = try? canvasBoard.save(record)
        reloadCanvases()
        if let saved {
            activeCanvasId = saved.id
        }
        canvasRevision += 1
        return saved
    }

    public func deleteCanvas(id: String) {
        try? canvasBoard.delete(id: id)
        if activeCanvasId == id {
            activeCanvasId = canvases.first(where: { $0.id != id })?.id
            if activeCanvasId == nil { canvasOpen = false }
        }
        reloadCanvases()
        canvasRevision += 1
    }

    public func previewURL(forCanvas id: String) -> URL {
        canvasBoard.previewURL(id: id)
    }

    public func canvasImageURL(id: String, fileName: String) -> URL {
        canvasBoard.imageURL(id: id, fileName: fileName)
    }

    public func activeCanvas() -> CanvasRecord? {
        activeCanvasId.flatMap { canvasBoard.load(id: $0) } ?? canvases.first
    }

    @discardableResult
    public func placeActiveScreenshot(botId: String) -> CanvasRecord? {
        guard let jpeg = canvasImageData(botId: botId, path: "") else { return nil }
        let title = activeCanvas()?.title ?? "Screenshot"
        let saved = try? canvasBoard.placeImage(canvasId: activeCanvasId, title: title, jpeg: jpeg)
        reloadCanvases()
        if let saved {
            activeCanvasId = saved.id
        }
        canvasRevision += 1
        return saved
    }

    private func canvasImageData(botId: String, path: String) -> Data? {
        if !path.isEmpty {
            // Resolve like every other file tool: a relative path means the
            // run's working folder when one is set, and the bot home
            // otherwise. Reading only the home is why an image the bot had
            // just written to its working folder came back "No image to
            // place."
            let bot = bots.first(where: { $0.id == botId })
            let resolved = bot.map { WorkingFolder.resolve(path, workingFolder: effectiveWorkingFolder(for: $0)) } ?? path
            var candidates: [URL] = []
            if BotHomeStore.isHostPath(resolved) {
                candidates.append(URL(fileURLWithPath: BotHomeStore.expandPath(resolved)))
            }
            if let home = try? botHome.homeURL(botId: botId) {
                candidates.append(home.appendingPathComponent(path))
            }
            for url in candidates {
                if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            }
            return nil
        }
        if let home = try? botHome.homeURL(botId: botId) {
            let shot = home.appendingPathComponent(".computer/screen.jpg")
            if let data = try? Data(contentsOf: shot), !data.isEmpty { return data }
        }
        return nil
    }

    private func autoBootIfNeeded(botId: String) {
        guard let computer = computers[botId] else { return }
        if computer.state == .booting || computer.state == .suspended { return }
        if computer.state == .running && computer.screenAvailable { return }
        boot(botId: botId, force: true)
    }

    public func boot(botId: String, force: Bool) {
        guard var computer = computers[botId] else { return }
        if !force, computer.state == .running || computer.state == .booting { return }
        computer.state = .booting
        computer.screenAvailable = false
        computers[botId] = computer
        booting = true
        save()

        bootTasks[botId]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if let home = try? self.botHome.homeURL(botId: botId) {
                let bot = self.bots.first(where: { $0.id == botId })
                let mode = (bot?.computerMode == .auto ? self.appConfig.defaultComputerMode : bot?.computerMode) ?? .auto
                await self.computerRuntime?.setSession(
                    botId: botId,
                    thisMac: mode == .thisMac,
                    persistent: mode != .off
                )
                await self.computerRuntime?.attach(botId: botId, homeURL: home)
                if let snap = await self.computerRuntime?.snapshot(botId: botId) {
                    let url = home.appendingPathComponent(".computer/screen.jpg")
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? snap.jpeg.write(to: url)
                }
            }
            await self.sleep(0.2)
            guard !Task.isCancelled else { return }
            guard var c = self.computers[botId] else { return }
            c.state = .running
            c.screenAvailable = true
            self.computers[botId] = c
            self.booting = false
            self.save()
            self.bootTasks.removeValue(forKey: botId)
        }
        bootTasks[botId] = task
    }

    public func takeControl(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .user
        if computer.state == .suspended {
            computer.state = .running
            computer.screenAvailable = true
        }
        computers[botId] = computer
        recordAudit(
            type: .computerControlTaken,
            botId: botId,
            tool: nil,
            reason: "Person took control.",
            allowed: true,
            forwarded: true
        )
        save()
    }

    /// Mirrors rakazo `releaseComputer`: release control and close the full-window overlay.
    public func release(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .bot
        computers[botId] = computer
        computerOpen = false
        canvasOpen = false
        recordAudit(
            type: .computerControlReleased,
            botId: botId,
            tool: nil,
            reason: "Person released control.",
            allowed: true,
            forwarded: true
        )
        save()
    }

    /// Keep-alive while the computer panel or overlay is open (rakazo `computer.heartbeat`).
    public func heartbeat(botId: String) {
        guard var computer = computers[botId], computer.state == .running else { return }
        computer.lastHeartbeatAt = .now
        computers[botId] = computer
    }

    // MARK: - Routines

    public func routines(for botId: String) -> [Routine] {
        routines[botId] ?? []
    }

    public func openNewRoutine() {
        editingRoutineId = nil
        routineDraft = RoutineDraft(botId: activeBotId ?? visibleBots.first?.id ?? "")
        panel = .routine
    }

    public func openRoutine(_ routine: Routine) {
        editingRoutineId = routine.id
        routineDraft = RoutineDraft(
            name: routine.name,
            prompt: routine.prompt,
            preset: Cron.preset(fromCron: routine.cron),
            botId: routine.botId
        )
        panel = .routine
    }

    @discardableResult
    public func createRoutine(
        botId: String,
        name: String,
        prompt: String,
        cron: String,
        timezone: String = "UTC",
        active: Bool = true,
        notify: Bool = true
    ) -> Routine {
        let targetBotId = bots.contains(where: { $0.id == botId })
            ? botId
            : (activeBotId ?? bots.first?.id ?? botId)

        // Editing: may reassign to another bot.
        if let editing = editingRoutineId {
            for (ownerId, list) in routines {
                guard let idx = list.firstIndex(where: { $0.id == editing }) else { continue }
                var updated = list[idx]
                updated.name = name
                updated.prompt = prompt
                updated.cron = cron
                updated.timezone = timezone
                updated.active = active
                updated.notify = notify
                updated.nextRunAt = Cron.nextDate(cron, from: .now)
                updated.botId = targetBotId

                if ownerId == targetBotId {
                    var next = list
                    next[idx] = updated
                    routines[ownerId] = next
                } else {
                    var fromList = list
                    fromList.remove(at: idx)
                    routines[ownerId] = fromList
                    var toList = routines[targetBotId] ?? []
                    toList.append(updated)
                    routines[targetBotId] = toList
                }
                save()
                return updated
            }
        }

        let routine = Routine(
            id: Ids.new(),
            botId: targetBotId,
            name: name,
            prompt: prompt,
            cron: cron,
            timezone: timezone,
            active: active,
            notify: notify,
            nextRunAt: Cron.nextDate(cron, from: .now)
        )
        var list = routines[targetBotId] ?? []
        list.append(routine)
        routines[targetBotId] = list
        save()
        return routine
    }

    public func saveRoutineDraft(botId: String? = nil) {
        let assigned = {
            let draftBot = routineDraft.botId
            if !draftBot.isEmpty, bots.contains(where: { $0.id == draftBot }) { return draftBot }
            if let botId, bots.contains(where: { $0.id == botId }) { return botId }
            return activeBotId ?? visibleBots.first?.id ?? ""
        }()
        guard !assigned.isEmpty else { return }

        let name = routineDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routineDraft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = createRoutine(
            botId: assigned,
            name: name.isEmpty ? "Routine" : name,
            prompt: prompt.isEmpty ? "Check in." : prompt,
            cron: Cron.fromPreset(routineDraft.preset)
        )
        editingRoutineId = nil
        panel = .computer
        if activeBotId != assigned {
            selectBot(assigned)
        }
    }

    public func assignRoutine(_ routineId: String, toBotId: String) {
        guard bots.contains(where: { $0.id == toBotId }) else { return }
        for (ownerId, list) in routines {
            guard let idx = list.firstIndex(where: { $0.id == routineId }) else { continue }
            var routine = list[idx]
            routine.botId = toBotId
            if ownerId == toBotId {
                var next = list
                next[idx] = routine
                routines[ownerId] = next
            } else {
                var fromList = list
                fromList.remove(at: idx)
                routines[ownerId] = fromList
                var toList = routines[toBotId] ?? []
                toList.append(routine)
                routines[toBotId] = toList
            }
            save()
            return
        }
    }

    public func deleteRoutine(_ routineId: String) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?.remove(at: idx)
            if editingRoutineId == routineId {
                editingRoutineId = nil
                panel = .computer
            }
            save()
            return
        }
    }

    /// Run a specific routine (OpenMausBot `/api/routines/:id/run`).
    public func runRoutine(_ routineId: String) {
        guard let botId = routines.first(where: { $0.value.contains(where: { $0.id == routineId }) })?.key,
              let routine = routines[botId]?.first(where: { $0.id == routineId }) else { return }
        fireRoutine(botId: botId, routine: routine)
    }

    public func runNow(botId: String) {
        let list = routines[botId] ?? []
        let now = Date.now
        guard let routine = list.first(where: { $0.active && ($0.nextRunAt.map { $0 <= now } ?? true) })
            ?? list.first(where: \.active)
            ?? list.first
        else {
            openNewRoutine()
            return
        }
        fireRoutine(botId: botId, routine: routine)
    }

    private func fireRoutine(botId: String, routine: Routine) {
        if !headlessRoutineTick {
            selectBot(botId)
            showChat()
        }
        let key = threadKey(for: botId)
        guard var thread = threads[key] ?? threads[botId] else {
            threads[botId] = ThreadData(threadId: bots.first(where: { $0.id == botId })?.threadId ?? Ids.new())
            guard var created = threads[botId] else { return }
            appendRoutineRun(botId: botId, routine: routine, thread: &created, threadKey: botId)
            return
        }
        appendRoutineRun(botId: botId, routine: routine, thread: &thread, threadKey: key)
    }

    private func appendRoutineRun(botId: String, routine: Routine, thread: inout ThreadData, threadKey: String) {
        let bot = bots.first(where: { $0.id == botId })
        if let bot, let reason = RoutineTickPolicy.skipReason(canRunLLM: canRunLLM(for: bot)) {
            let meta = ThreadMessage(
                id: Ids.new(),
                threadId: thread.threadId,
                seq: thread.nextSeq,
                role: .system,
                blocks: [.meta("Routine '\(routine.name)' skipped — no model connected")]
            )
            thread.messages.append(meta)
            thread.cursor = meta.seq
            threads[threadKey] = thread
            if let idx = routines[botId]?.firstIndex(where: { $0.id == routine.id }) {
                routines[botId]?[idx].lastRunAt = .now
                routines[botId]?[idx].nextRunAt = Cron.nextDate(routine.cron, from: .now)
                routines[botId]?[idx].inProgress = false
            }
            appendRunLog(botId: botId, kind: "routine", text: reason)
            save()
            return
        }

        let meta = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .system,
            blocks: [.meta("Routine '\(routine.name)' fired")]
        )
        thread.messages.append(meta)
        thread.cursor = meta.seq

        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: "routine",
            routineId: routine.id
        )
        thread.run = run
        threads[threadKey] = thread

        if let idx = routines[botId]?.firstIndex(where: { $0.id == routine.id }) {
            routines[botId]?[idx].lastRunAt = .now
            routines[botId]?[idx].inProgress = true
            routines[botId]?[idx].lastError = nil
        }
        save()

        let runId = run.id
        let prompt = routine.prompt
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: prompt)
        }
        runTasks[runId] = task
    }

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

    private func mergeCatalog(_ incoming: [ConnectionItem], addingNew: Bool = true) {
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

    private func storeAccountPreferenceFromTool(slug: String, account: String) {
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

    private func writePlugin(slug: String, title: String, body: String, account: String? = nil) async throws -> String {
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

    private func deletePlugin(slug: String, id: String) async throws -> String {
        let token = connectionSecrets[slug]
        if let googleToken = try await liveGoogleAccessToken(for: slug) {
            return try await pluginClient.delete(slug: slug, token: googleToken, id: id)
        }
        guard let token, token != ComposioClient.composioTokenSentinel, token != Self.googleTokenSentinel else {
            throw PluginError.rejected("Plugin \(slug) is not connected.")
        }
        return try await pluginClient.delete(slug: slug, token: token, id: id)
    }

    private func readPlugin(slug: String, query: String, account: String? = nil) async throws -> String {
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

    private func recordAudit(
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

    private func resolvePolicyElement(tool: String, argumentsJSON: String, botId: String) -> PolicyElement? {
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

    private func recordBootBoundary() {
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

    private func syncPluginKnowledge(query: String, botId: String) async {
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

    private func knowledgeDocuments() -> [MemoryDocument] {
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

    private func gatedWrite(
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

    private static func approvalFunctionName(_ tool: String) -> String {
        switch tool {
        case "shell.exec": return "shell"
        case "read_file.host": return "read_file"
        case "list_files.host": return "list_files"
        case "write_file.host": return "write_file"
        case "edit_file.host": return "edit_file"
        case "move_file.host": return "move_file"
        case "delete_file.host": return "delete_file"
        default: return tool
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

    private func computerBlockedIfHeadless(bot: Bot) -> AgentToolCallResult? {
        guard headlessRoutineTick else { return nil }
        guard resolvedComputerMode(for: bot) == .thisMac else { return nil }
        return AgentToolCallResult(
            output: "This Mac computer is unavailable during a background routine tick. Screen Recording and Accessibility need GrizzyBot in the foreground. Open the app to run computer tools, or switch this bot to In-app browser."
        )
    }

    /// Applies computer mode to the runtime and attaches the bot home before screen I/O.
    @discardableResult
    private func prepareComputerSurface(botId: String, bot: Bot) async -> URL {
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

    private func computerNote(for bot: Bot) -> String {
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

    private func appendLiveTool(threadKey: String, runId: String, name: String, result: AgentToolCallResult) {
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
            if run?.status.isActive == true, run?.trigger == "routine" {
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
                routines[botId]?[idx].nextRunAt = Cron.backoffDate(failCount: fails, from: now)
            }
        }
    }

    // MARK: - Usage / export / deployment

    public func weeklySummary() -> UsageSummary {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        let recent = usage.filter { $0.createdAt >= cutoff }
        return UsageSummary(
            inputTokens: recent.reduce(0) { $0 + $1.inputTokens },
            outputTokens: recent.reduce(0) { $0 + $1.outputTokens },
            runs: recent.count
        )
    }

    /// Billed tokens for one bot's chat: last first-call prompt, plus lifetime sent/received.
    public func chatTokenStats(botId: String) -> ChatTokenStats {
        let records = usage.filter { $0.botId == botId }
        let last = records.max(by: { $0.createdAt < $1.createdAt })
        return ChatTokenStats(
            lastPromptTokens: last?.billedPromptTokens ?? 0,
            sentTokens: records.reduce(0) { $0 + $1.inputTokens },
            receivedTokens: records.reduce(0) { $0 + $1.outputTokens }
        )
    }

    /// Zeros composer Prompt / Sent / Recv. Pass a bot id for that bot only; `nil` clears every bot.
    /// Chat messages, memory, and files are left alone. Weekly usage uses the same ledger.
    @discardableResult
    public func resetChatTokens(botId: String? = nil) -> Int {
        let before = usage.count
        if let botId {
            usage.removeAll { $0.botId == botId }
        } else {
            usage.removeAll()
        }
        let removed = before - usage.count
        save()
        return removed
    }

    public func exportManifest(botId: String, redacted: Bool = false) -> ExportManifest? {
        guard let bot = bots.first(where: { $0.id == botId }) else { return nil }
        let mem = memory.filter { $0.botId == botId }.map {
            ExportManifest.MemoryEntry(path: $0.path, content: $0.content)
        }
        let rts = (routines[botId] ?? []).map {
            ExportManifest.RoutineExport(name: $0.name, prompt: $0.prompt, cron: $0.cron, timezone: $0.timezone)
        }
        let fileEntries = files.map { ExportManifest.FileEntry(path: $0[0], content: $0.count > 1 ? $0[1] : "") }
        let history = threads[botId]?.messages ?? []
        let manifest = ExportManifest(
            bot: .init(
                name: bot.name,
                title: bot.title,
                description: bot.description,
                instructions: bot.instructions
            ),
            memory: mem,
            routines: rts,
            files: fileEntries,
            history: history
        )
        return redacted ? manifest.redacted() : manifest
    }

    public func setComputerHost(_ host: String) {
        deployment.computerHost = ComputerHost.normalize(host)?.rawValue ?? ComputerHost.inAppBrowser.rawValue
        showHostPrompt = false
        save()
    }

    public func exportFilename(for botId: String) -> String {
        let name = bots.first(where: { $0.id == botId })?.name ?? "bot"
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(slug)-export.json"
    }

    // MARK: - Chat / workspace sessions

    public var activeSessionKey: String? {
        if let groupId = activeGroupId { return groupId }
        guard let botId = activeBotId else { return nil }
        return threadKey(for: botId)
    }

    public var activeSessionTitle: String {
        if let groupId = activeGroupId {
            return groups.first(where: { $0.id == groupId })?.name ?? "Room"
        }
        if let bot = activeBot {
            if let taskId = bot.activeTaskId,
               let task = bot.tasks.first(where: { $0.id == taskId }) {
                return "\(bot.name) · \(task.title)"
            }
            return bot.name
        }
        return "Chat"
    }

    public var activeSessionMessageCount: Int {
        guard let key = activeSessionKey else { return 0 }
        return threads[key]?.messages.count ?? 0
    }

    public func clearActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
        }
        let threadId = threads[key]?.threadId ?? Ids.new()
        threads[key] = ThreadData(threadId: threadId)
        if let botId = activeBotId, key == botId, let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].preview = ""
            bots[idx].updatedAt = .now
        }
        if let groupId = activeGroupId, let gIdx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[gIdx].preview = ""
        }
        save()
    }

    /// Same as clear for the main thread; deletes a task thread entirely.
    public func deleteActiveChat() {
        guard let key = activeSessionKey else { return }
        if let botId = activeBotId, activeGroupId == nil {
            stopRun(botId: botId)
            if let idx = bots.firstIndex(where: { $0.id == botId }),
               bots[idx].activeTaskId == key {
                bots[idx].tasks.removeAll { $0.id == key }
                bots[idx].activeTaskId = nil
                threads.removeValue(forKey: key)
                bots[idx].updatedAt = .now
                save()
                return
            }
        }
        clearActiveChat()
    }

    public func exportActiveChat() -> ChatSessionExport? {
        guard let key = activeSessionKey, let thread = threads[key] else { return nil }
        return ChatSessionExport(
            threadId: thread.threadId,
            title: activeSessionTitle,
            botId: activeGroupId == nil ? activeBotId : nil,
            groupId: activeGroupId,
            messages: thread.messages
        )
    }

    public func exportActiveChatJSON() -> Data? {
        guard let export = exportActiveChat() else { return nil }
        return try? userPersistence.encodeJSON(export)
    }

    public func exportActiveChatMarkdown() -> String {
        guard let export = exportActiveChat() else { return "" }
        var lines = [
            "# \(export.title)",
            "",
            "_Exported \(ISO8601DateFormatter().string(from: export.exportedAt))_",
            "",
        ]
        for message in export.messages {
            let speaker: String
            switch message.role {
            case .user: speaker = "You"
            case .bot: speaker = export.title
            case .system: speaker = "System"
            }
            let body = message.firstText.isEmpty ? transcriptBody(message) : message.firstText
            lines.append("**\(speaker)**")
            lines.append("")
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func chatExportFilename(json: Bool) -> String {
        let slug = activeSessionTitle
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "·", with: "")
        return json ? "\(slug)-chat.json" : "\(slug)-chat.md"
    }

    public func importChat(_ export: ChatSessionExport) {
        guard let key = activeSessionKey else { return }
        let threadId = threads[key]?.threadId ?? export.threadId
        var thread = ThreadData(threadId: threadId, messages: export.messages)
        thread.cursor = export.messages.map(\.seq).max() ?? -1
        threads[key] = thread
        save()
    }

    @discardableResult
    public func saveWorkspaceSnapshot(name: String? = nil) -> WorkspaceSnapshotMeta? {
        guard let userId = session?.userId else { return nil }
        let ws = currentWorkspace()
        let messageCount = ws.threads.values.reduce(0) { $0 + $1.messages.count }
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        let meta = WorkspaceSnapshotMeta(
            name: {
                let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "Snapshot \(stamp)" : trimmed
            }(),
            botCount: ws.bots.count,
            messageCount: messageCount
        )
        let stripped = WorkspaceSecrets.from(workspace: ws).stripped(from: ws)
        userPersistence.saveSnapshot(WorkspaceSnapshot(meta: meta, workspace: stripped), userId: userId)
        return meta
    }

    public func listWorkspaceSnapshots() -> [WorkspaceSnapshotMeta] {
        guard let userId = session?.userId else { return [] }
        return userPersistence.listSnapshots(userId: userId)
    }

    @discardableResult
    public func restoreWorkspaceSnapshot(_ id: String) -> Bool {
        guard let userId = session?.userId,
              let snapshot = userPersistence.loadSnapshot(id: id, userId: userId) else { return false }
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        var ws = snapshot.workspace
        if let secrets = SecretStore.load(userId: userId) {
            ws = secrets.applying(to: ws)
        }
        applyWorkspace(ws)
        route = bots.isEmpty ? .onboarding : .shell
        save()
        return true
    }

    public func deleteWorkspaceSnapshot(_ id: String) {
        guard let userId = session?.userId else { return }
        userPersistence.deleteSnapshot(id: id, userId: userId)
    }

    public func exportWorkspaceJSON() -> Data? {
        guard session?.userId != nil else { return nil }
        let stripped = WorkspaceSecrets.from(workspace: currentWorkspace())
            .stripped(from: currentWorkspace())
        return try? userPersistence.encodeJSON(stripped)
    }

    public func workspaceExportFilename() -> String {
        let slug = (session?.name ?? "workspace")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(slug)-workspace.json"
    }

    /// Wipe bots, chats, routines, and files. Keeps the signed-in account.
    public func deleteWorkspace() {
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(UserWorkspace())
        route = .onboarding
        showHostPrompt = false
        save()
    }

    private func transcriptBody(_ message: ThreadMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .meta(let t): return t
            case .ask(let t, _): return t
            case .card(let lines):
                return lines.map { "\($0.k): \($0.v)" }.joined(separator: "\n")
            case .subagent(_, let name, let task, let status, _, let result):
                return "[\(name) \(status.rawValue)] \(task)" + (result.map { " — \($0)" } ?? "")
            case .childBot(_, let name, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .approval(let tool, let detail, let status):
                return "[\(status.rawValue)] \(tool): \(detail)"
            case .choice(let question, _, _):
                return question
            case .connect(let name, _, _, let status):
                return "[\(status.rawValue)] \(name)"
            case .computer(let state, let text):
                return "[\(state)] \(text)"
            case .progress(let t):
                return StreamText.visible(t)
            case .component(let payload):
                return payload.title
            case .artifact(let id, let title, let kind, let summary, let deleted):
                return deleted
                    ? "[artifact deleted] \(title) (\(id))"
                    : "[artifact \(kind.rawValue)] \(title) (\(id)) — \(summary)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - OpenMausBot-inspired surfaces

    public var visibleBots: [Bot] {
        bots.filter { !$0.hidden }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    public func openAppSettings(section: AppSettingsSection = .general) {
        appSettingsSection = section
        appSettingsOpen = true
    }

    /// Empty workspaces land on onboarding. UI tests need the shell overlays.
    public func prepareUITestWorkspace() {
        if bots.isEmpty {
            _ = createBot(name: "UI Test")
        }
        route = .shell
        showHostPrompt = false
        modelSettingsOpen = false
        pluginsOpen = false
        skillsOpen = false
        appSettingsOpen = false
        computerOpen = false
        canvasOpen = false
    }

    public func closeAppSettings() {
        appSettingsOpen = false
    }

    public func saveAppConfig(_ config: AppConfig) {
        appConfig = config
        if var session {
            if !config.profileName.isEmpty { session.name = config.profileName }
            if !config.profileEmail.isEmpty { session.email = config.profileEmail }
            self.session = session
        }
        applyBoxToken(config.boxToken, persist: false)
        save()
        refreshLocalIntegrations()
    }

    /// Restart folder watchers + local OpenAI/MCP gateway from current config.
    public func refreshLocalIntegrations() {
        Task { await self.syncFolderWatchers() }
        Task { await self.syncLocalGateway() }
    }

    public func reloadFolderWatchers() {
        folderWatchers = (try? FolderWatcherPersistence.loadAll(root: userPersistence.root)) ?? []
    }

    public func saveFolderWatcher(_ watcher: FolderWatcherRecord) throws {
        var record = watcher
        record.watchPath = (record.watchPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.watchPath.isEmpty else {
            throw FolderWatcherError.emptyPath
        }
        try FolderWatcherPersistence.save(record, root: userPersistence.root)
        reloadFolderWatchers()
        refreshLocalIntegrations()
    }

    public func deleteFolderWatcher(id: String) throws {
        FolderWatcherSuppression.shared.release(id)
        try FolderWatcherPersistence.delete(id: id, root: userPersistence.root)
        reloadFolderWatchers()
        refreshLocalIntegrations()
    }

    /// Sends the watcher prompt to its bot immediately (does not wait for FSEvents).
    @discardableResult
    public func runFolderWatcherNow(id: String) -> String {
        guard let watcher = folderWatchers.first(where: { $0.id == id }) else {
            return FolderWatcherError.notFound.localizedDescription
        }
        let result = fireFolderWatcher(watcher, changedPaths: [], manual: true)
        var updated = watcher
        if result.hasPrefix("No bot") {
            updated.lastError = result
        } else if result.hasPrefix("Triggered") {
            updated.lastTriggeredAt = FolderWatcherRecord.isoNow()
            updated.lastError = nil
            if let botId = updated.botId ?? activeBotId ?? bots.first?.id {
                selectBot(botId)
            }
        }
        try? FolderWatcherPersistence.save(updated, root: userPersistence.root)
        reloadFolderWatchers()
        return result
    }

    public func discoverMcpBonjour(timeoutSeconds: TimeInterval = 5) async -> [MCPBonjourDiscovery.Entry] {
        await MCPBonjourDiscovery.discover(timeoutSeconds: timeoutSeconds)
    }

    public func memoryDedupeClusters(botId: String) -> [MemoryFactCluster] {
        let content = memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
        return MemoryFactDedupe.clusters(from: MemoryLedger.parse(content).facts)
    }

    @discardableResult
    public func mergeMemoryDuplicates(botId: String) -> [String] {
        guard let idx = memory.firstIndex(where: { $0.botId == botId && $0.path == "MEMORY.md" }) else {
            return []
        }
        let result = MemoryFactDedupe.mergeContent(memory[idx].content)
        memory[idx].content = result.text
        memory[idx].updatedAt = .now
        save()
        return result.removed
    }

    private func syncFolderWatchers() async {
        let root = userPersistence.root
        let runner = StoreFolderWatcherRunner { [weak self] watcher, paths, manual in
            guard let self else { return "store released" }
            return await MainActor.run {
                self.fireFolderWatcher(watcher, changedPaths: paths, manual: manual)
            }
        }
        await FolderWatcherService.shared.configure(root: root, runner: runner)
        if appConfig.enableFolderWatchers {
            await FolderWatcherService.shared.start()
            await FolderWatcherService.shared.reloadNow()
        } else {
            await FolderWatcherService.shared.stop()
        }
    }

    /// Test/UI seam: apply an automatic FSEvent-style fire (honors busy + cooldown skips).
    @discardableResult
    public func handleFolderWatcherEvent(id: String, changedPaths: [String]) -> String {
        guard let watcher = folderWatchers.first(where: { $0.id == id }) else {
            return FolderWatcherError.notFound.localizedDescription
        }
        return fireFolderWatcher(watcher, changedPaths: changedPaths, manual: false)
    }

    private func fireFolderWatcher(
        _ watcher: FolderWatcherRecord,
        changedPaths: [String],
        manual: Bool
    ) -> String {
        let botId = watcher.botId ?? activeBotId ?? bots.first?.id
        guard let botId else { return "No bot configured for watcher." }
        if let skip = FolderWatcherFirePolicy.skipReason(
            botBusy: isRunActive(botId: botId),
            suppressed: FolderWatcherSuppression.shared.isSuppressed(watcher.id),
            manual: manual
        ) {
            return skip
        }
        FolderWatcherSuppression.shared.suppress(watcher.id)
        watcherRunByBotId[botId] = watcher.id
        Task { await FolderWatcherService.shared.dropPending(watcherId: watcher.id) }
        let prompt = FolderWatcherPromptBuilder.userMessage(
            watcher: watcher,
            changedPaths: changedPaths,
            manual: manual
        )
        let watchPath = (watcher.watchPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        send(
            botId: botId,
            text: prompt,
            workingFolderOverride: watchPath.isEmpty ? nil : watchPath
        )
        return "Triggered bot \(botId)"
    }

    private func watcherEchoCooldown(for watcherId: String) -> TimeInterval {
        let responsiveness = folderWatchers.first(where: { $0.id == watcherId })?.responsiveness ?? "balanced"
        return FolderWatcherGlobMatching.debounceSeconds(for: responsiveness)
    }

    private func releaseWorkingFolderOverrideIfNeeded(botId: String) {
        let status = threads[threadKey(for: botId)]?.run?.status
        switch status {
        case .waitingInput, .waitingTakeover, .queued, .leased, .running:
            return
        default:
            runWorkingFolderOverride.removeValue(forKey: botId)
            releaseWatcherSuppressionIfNeeded(botId: botId)
        }
    }

    private func releaseWatcherSuppressionIfNeeded(botId: String) {
        guard let watcherId = watcherRunByBotId.removeValue(forKey: botId) else { return }
        let cooldown = watcherEchoCooldown(for: watcherId)
        Task {
            try? await Task.sleep(for: .seconds(cooldown))
            FolderWatcherSuppression.shared.release(watcherId)
            await FolderWatcherService.shared.dropPending(watcherId: watcherId)
        }
    }

    private func syncLocalGateway() async {
        let settings = appConfig.localGateway
        let botPairs = bots.map { (id: $0.id, name: $0.name) }
        await LocalOpenAIGateway.shared.configure(
            settings: settings,
            bots: botPairs,
            handler: { [weak self] botId, messages, _ in
                guard let self else { throw PrivacyFilterBlockedError.criticalPII([.apiKey]) }
                return try await MainActor.run {
                    try self.handleLocalGatewayChat(botId: botId, messages: messages)
                }
            }
        )
        await LocalOpenAIGateway.shared.restart()
    }

    private func handleLocalGatewayChat(botId: String?, messages: [[String: String]]) throws -> String {
        let target = botId ?? appConfig.localGateway.defaultBotId ?? activeBotId ?? bots.first?.id
        guard let target else {
            throw NSError(
                domain: "GrizzyBot",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No bot available"]
            )
        }
        let prompt = messages.reversed().first(where: { $0["role"] == "user" })?["content"]
            ?? messages.last?["content"]
            ?? ""
        let scrubbed = try PrivacyFilter.applyForSend(
            prompt,
            settings: appConfig.privacyFilter,
            logDirectory: userPersistence.root,
            logContext: "local_gateway"
        )
        send(botId: target, text: scrubbed)
        return "Queued on bot \(target). Open GrizzyBot to follow the run."
    }

    private func applyBoxToken(_ token: String?, persist: Bool) {
        mergeCatalog(ConnectionCatalog.defaults)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if connectionSecrets["box"] != ComposioClient.composioTokenSentinel {
                connectionSecrets.removeValue(forKey: "box")
            }
            if let idx = connections.firstIndex(where: { $0.slug == "box" }),
               connections[idx].viaComposio == false {
                connections[idx].connected = false
                connections[idx].accountLabel = nil
            }
            if persist { save() }
            return
        }
        if connectionSecrets["box"] != ComposioClient.composioTokenSentinel {
            connectionSecrets["box"] = trimmed
        }
        if let idx = connections.firstIndex(where: { $0.slug == "box" }),
           connections[idx].viaComposio == false {
            connections[idx].connected = true
            connections[idx].accountLabel = connections[idx].accountLabel ?? "Box token"
        }
        if persist { save() }
    }

    public func showRoutinesPage() {
        mainView = .routines
        panel = nil
        activeGroupId = nil
    }

    public func showChat() {
        mainView = .chat
    }

    public func selectGroup(_ groupId: String) {
        activeGroupId = groupId
        activeBotId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        canvasOpen = false
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].unread = false
            save()
        }
    }

    public func selectBot(_ botId: String) {
        activeBotId = botId
        activeGroupId = nil
        mainView = .chat
        panel = nil
        computerOpen = false
        canvasOpen = false
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].unread = false
            save()
        }
    }

    @discardableResult
    public func duplicateBot(_ botId: String) -> Bot? {
        guard let source = bots.first(where: { $0.id == botId }) else { return nil }
        let copy = createBot(
            name: "\(source.name) copy",
            title: source.title,
            description: source.description,
            instructions: source.instructions,
            parentBotId: source.parentBotId
        )
        if let idx = bots.firstIndex(where: { $0.id == copy.id }) {
            bots[idx].autoApprove = source.autoApprove
            bots[idx].speakReplies = source.speakReplies
            bots[idx].notifications = source.notifications
            bots[idx].computerMode = source.computerMode
            bots[idx].modelProvider = source.modelProvider
            bots[idx].modelId = source.modelId
            bots[idx].enabledTools = source.enabledTools
            save()
            return bots[idx]
        }
        return copy
    }

    public func setBotTool(_ botId: String, toolId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setTool(toolId, enabled: enabled)
        bots[idx].updatedAt = .now
        save()
    }

    public func setAllBotTools(_ botId: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].setAllTools(enabled: enabled, knownIds: knownToolIds)
        bots[idx].updatedAt = .now
        save()
    }

    public func setDefaultTool(_ toolId: String, enabled: Bool) {
        setDefaultTools([toolId], enabled: enabled)
    }

    public func setDefaultTools(_ toolIds: [String], enabled: Bool) {
        var config = appConfig
        for toolId in toolIds {
            if !config.seenToolIds.contains(toolId) {
                config.seenToolIds.append(toolId)
            }
            if enabled {
                if !config.defaultEnabledTools.contains(toolId) {
                    config.defaultEnabledTools.append(toolId)
                }
            } else {
                config.defaultEnabledTools.removeAll { $0 == toolId }
            }
        }
        appConfig = config
        save()
    }

    public func setAllDefaultTools(enabled: Bool) {
        var config = appConfig
        let ids = knownToolIds
        for id in ids where !config.seenToolIds.contains(id) {
            config.seenToolIds.append(id)
        }
        config.defaultEnabledTools = enabled ? ids : []
        appConfig = config
        save()
    }

    public var knownToolIds: [String] {
        var ids = AgentToolCatalog.allIds(custom: customTools, mcpServers: mcpServers)
        for server in mcpServers {
            ids.append(contentsOf: McpToolGate.childIds(serverId: server.id, names: mcpToolNames(for: server.id)))
        }
        return ids
    }

    public var knownToolDefinitions: [AgentToolDefinition] {
        AgentToolCatalog.definitions(custom: customTools, mcpServers: mcpServers)
    }

    public func mcpStatus(for serverId: String) -> McpProbeStatus {
        if let live = mcpProbeStatus[serverId] { return live }
        if let names = mcpAdvertisedTools[serverId] {
            return .connected(toolCount: names.count)
        }
        return .idle
    }

    public func mcpToolNames(for serverId: String) -> [String] {
        var names = McpCatalogPromote.uniqueAdvertisedNames(mcpAdvertisedTools[serverId] ?? [])
        var seen = Set(names)
        let server = mcpServers.first(where: { $0.id == serverId })
        for promo in mcpPromotedTools.values where promo.serverId == serverId {
            if McpCatalogPromote.isDispatcher(promo.chatName) { continue }
            if let server, promo.chatName == McpNativeNaming.chatName(server: server, tool: promo.executeTool),
               seen.contains(promo.executeTool) {
                continue
            }
            if seen.insert(promo.chatName).inserted {
                names.append(promo.chatName)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func mcpToolDescription(serverId: String, toolName: String) -> String {
        if let info = mcpListedTools[serverId]?.first(where: { $0.name == toolName }),
           !info.description.isEmpty {
            return info.description
        }
        if let promo = mcpPromotedTools.values.first(where: {
            $0.serverId == serverId && $0.chatName == toolName
        }), !promo.description.isEmpty {
            return promo.description
        }
        return "MCP tool"
    }

    public func isDefaultMcpToolEnabled(serverId: String, toolName: String) -> Bool {
        McpToolGate.isToolEnabled(
            enabledIds: appConfig.defaultEnabledTools,
            serverId: serverId,
            toolName: toolName,
            advertised: mcpToolNames(for: serverId)
        )
    }

    public func isBotMcpToolEnabled(botId: String, serverId: String, toolName: String) -> Bool {
        guard let bot = bots.first(where: { $0.id == botId }) else { return false }
        return McpToolGate.isToolEnabled(
            enabledIds: bot.enabledTools,
            serverId: serverId,
            toolName: toolName,
            advertised: mcpToolNames(for: serverId)
        )
    }

    public func setDefaultMcpChildTool(serverId: String, toolName: String, enabled: Bool) {
        var config = appConfig
        let advertised = mcpToolNames(for: serverId)
        McpToolGate.setChild(
            enabledIds: &config.defaultEnabledTools,
            serverId: serverId,
            toolName: toolName,
            enabled: enabled,
            advertised: advertised
        )
        let parent = "mcp:\(serverId)"
        for id in [parent] + McpToolGate.childIds(serverId: serverId, names: advertised) {
            if !config.seenToolIds.contains(id) {
                config.seenToolIds.append(id)
            }
        }
        appConfig = config
        save()
    }

    public func setBotMcpChildTool(botId: String, serverId: String, toolName: String, enabled: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        var tools = bots[idx].enabledTools
        McpToolGate.setChild(
            enabledIds: &tools,
            serverId: serverId,
            toolName: toolName,
            enabled: enabled,
            advertised: mcpToolNames(for: serverId)
        )
        bots[idx].enabledTools = tools
        bots[idx].updatedAt = .now
        save()
    }

    public func probeMcpServer(_ serverId: String) {
        guard let server = mcpServers.first(where: { $0.id == serverId }) else { return }
        if mcpProbeStatus[serverId] == .checking { return }
        let generation = (mcpProbeGeneration[serverId] ?? 0) + 1
        mcpProbeGeneration[serverId] = generation
        mcpProbeStatus[serverId] = .checking
        Task {
            let outcome: Result<[McpToolInfo], Error>
            do {
                outcome = .success(try await McpClient.listTools(server: server))
            } catch {
                outcome = .failure(error)
            }
            guard mcpProbeGeneration[serverId] == generation else { return }
            guard mcpServers.contains(where: { $0.id == serverId }) else { return }
            switch outcome {
            case .success(let listed):
                _ = applyMcpList(serverId: serverId, tools: listed)
            case .failure(let error):
                mcpProbeStatus[serverId] = .failed(error.localizedDescription)
            }
        }
    }

    public func probeAllMcpServers() {
        for server in mcpServers {
            probeMcpServer(server.id)
        }
    }

    @discardableResult
    public func addMcpServer(
        name: String,
        transport: McpTransport,
        command: String,
        args: [String],
        env: [String: String],
        url: String,
        headers: [String: String]
    ) -> McpServer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = McpServer(
            name: trimmed,
            transport: transport,
            command: command,
            args: FastFilesystemMcpArgs.normalize(command: command, args: args),
            env: env,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers
        )
        mcpServers.append(server)
        optInNewTool(server.toolId)
        save()
        return server
    }

    public func updateMcpServer(_ server: McpServer) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        var updated = server
        updated.args = FastFilesystemMcpArgs.normalize(command: updated.command, args: updated.args)
        mcpServers[idx] = updated
        save()
    }

    public func deleteMcpServer(_ serverId: String) {
        mcpServers.removeAll { $0.id == serverId }
        McpToolGate.stripServer(serverId, from: &appConfig.defaultEnabledTools)
        for i in bots.indices {
            McpToolGate.stripServer(serverId, from: &bots[i].enabledTools)
        }
        mcpAdvertisedTools[serverId] = nil
        mcpListedTools[serverId] = nil
        mcpProbeStatus[serverId] = nil
        mcpProbeGeneration[serverId] = nil
        mcpPromotedTools = mcpPromotedTools.filter { $0.value.serverId != serverId }
        save()
    }

    @discardableResult
    func optInNewTool(_ toolId: String) -> Bool {
        if appConfig.seenToolIds.contains(toolId) { return false }
        var config = appConfig
        config.seenToolIds.append(toolId)
        if !config.defaultEnabledTools.isEmpty, !config.defaultEnabledTools.contains(toolId) {
            config.defaultEnabledTools.append(toolId)
        }
        appConfig = config
        for i in bots.indices {
            if !bots[i].enabledTools.contains(toolId), !bots[i].noToolsEnabled {
                bots[i].enabledTools.append(toolId)
            }
        }
        return true
    }

    /// First launch after this field exists: record every known tool so disabled defaults stay off.
    private func seedSeenToolIdsIfNeeded() {
        guard appConfig.seenToolIds.isEmpty else { return }
        var seen = Set(AgentToolCatalog.builtinIds)
        seen.formUnion(CanvasBoardStore.toolIds)
        seen.formUnion(ArtifactStore.toolIds)
        seen.formUnion(appConfig.defaultEnabledTools)
        seen.formUnion(customTools.map(\.id))
        seen.formUnion(mcpServers.map(\.toolId))
        for (serverId, names) in mcpAdvertisedTools {
            seen.formUnion(McpToolGate.childIds(serverId: serverId, names: names))
        }
        for bot in bots {
            seen.formUnion(bot.enabledTools)
        }
        var config = appConfig
        config.seenToolIds = Array(seen)
        appConfig = config
        save()
    }

    @discardableResult
    public func addCustomTool(
        name: String,
        description: String,
        triggers: [String],
        responseTemplate: String
    ) -> CustomAgentTool? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let phraseList = triggers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tool = CustomAgentTool(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            triggers: phraseList.isEmpty ? [trimmed.lowercased()] : phraseList,
            responseTemplate: responseTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ran **{name}** on: {prompt}"
                : responseTemplate
        )
        customTools.append(tool)
        optInNewTool(tool.id)
        save()
        return tool
    }

    public func updateCustomTool(_ tool: CustomAgentTool) {
        guard let idx = customTools.firstIndex(where: { $0.id == tool.id }) else { return }
        customTools[idx] = tool
        save()
    }

    public func deleteCustomTool(_ toolId: String) {
        customTools.removeAll { $0.id == toolId }
        appConfig.defaultEnabledTools.removeAll { $0 == toolId }
        for i in bots.indices {
            bots[i].enabledTools.removeAll { $0 == toolId }
        }
        save()
    }

    public func setBotPinned(_ botId: String, pinned: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].pinned = pinned
        save()
    }

    public func setBotHidden(_ botId: String, hidden: Bool) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].hidden = hidden
        if hidden, activeBotId == botId {
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public func markBotUnread(_ botId: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].unread = true
        save()
    }

    public func setChiefOfStaff(_ botId: String, enabled: Bool) {
        for i in bots.indices {
            bots[i].chiefOfStaff = enabled && bots[i].id == botId
        }
        save()
    }

    public func patchBot(
        _ botId: String,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        color: String? = nil,
        autoApprove: Bool? = nil,
        speakReplies: Bool? = nil,
        notifications: Bool? = nil,
        computerMode: ComputerMode? = nil,
        modelProvider: String? = nil,
        modelId: String? = nil,
        visibility: BotVisibility? = nil,
        runtime: BotRuntime? = nil,
        aguiURL: String? = nil,
        enabledComponents: [String]? = nil
    ) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let name { bots[idx].name = name }
        if let title { bots[idx].title = title }
        if let description { bots[idx].description = description }
        if let instructions { bots[idx].instructions = instructions }
        if let color { bots[idx].color = color }
        if let autoApprove { bots[idx].autoApprove = autoApprove }
        if let speakReplies { bots[idx].speakReplies = speakReplies }
        if let notifications { bots[idx].notifications = notifications }
        if let computerMode { bots[idx].computerMode = computerMode }
        if let modelProvider { bots[idx].modelProvider = modelProvider }
        if let modelId { bots[idx].modelId = modelId }
        if let visibility { bots[idx].visibility = visibility }
        if let runtime { bots[idx].runtime = runtime }
        if let aguiURL {
            let trimmed = aguiURL.trimmingCharacters(in: .whitespacesAndNewlines)
            bots[idx].aguiURL = trimmed.isEmpty ? nil : trimmed
        }
        if let enabledComponents { bots[idx].enabledComponents = enabledComponents }
        bots[idx].updatedAt = .now
        save()
    }

    public func setBotModel(_ botId: String, choice: BotModelChoice) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        switch choice {
        case .workspaceDefault:
            bots[idx].modelProvider = nil
            bots[idx].modelId = nil
        case .catalog(let provider, let modelId, _):
            bots[idx].modelProvider = provider
            bots[idx].modelId = modelId
        }
        bots[idx].updatedAt = .now
        save()
    }

    @discardableResult
    public func createGroup(name: String, memberIds: [String]) -> GroupRoom {
        let members = memberIds.isEmpty ? Array(visibleBots.prefix(2).map(\.id)) : memberIds
        let group = GroupRoom(name: name, memberIds: members)
        groups.append(group)
        threads[group.id] = ThreadData(threadId: group.threadId)
        activeGroupId = group.id
        activeBotId = nil
        mainView = .chat
        save()
        return group
    }

    public func updateGroupBulletin(_ groupId: String, bulletin: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].bulletin = bulletin
        save()
    }

    public func sendGroupMessage(groupId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var thread = threads[groupId] else { return }
        guard let gIdx = groups.firstIndex(where: { $0.id == groupId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(trimmed)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        threads[groupId] = thread
        groups[gIdx].preview = trimmed
        save()

        let responderId: String? = {
            switch groups[gIdx].defaultResponder {
            case .member(let id): return id
            case .everyone, .mentions:
                return groups[gIdx].memberIds.first
            }
        }()
        guard let responderId, bots.contains(where: { $0.id == responderId }) else { return }

        var t2 = threads[groupId] ?? thread
        let run = Run(
            id: Ids.new(),
            botId: responderId,
            threadId: t2.threadId,
            status: .running,
            trigger: "group"
        )
        t2.run = run
        threads[groupId] = t2
        if let idx = bots.firstIndex(where: { $0.id == responderId }) {
            bots[idx].status = "working"
        }
        save()
        let runId = run.id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(botId: responderId, threadKey: groupId, runId: runId, prompt: trimmed)
        }
        runTasks[runId] = task
    }

    @discardableResult
    public func createTask(botId: String, title: String) -> BotTask? {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return nil }
        let task = BotTask(title: title.isEmpty ? "New task" : title)
        bots[idx].tasks.append(task)
        bots[idx].activeTaskId = task.id
        threads[task.id] = ThreadData(threadId: task.threadId)
        // Point bot.threadId at the task thread for chat routing.
        bots[idx].threadId = task.threadId
        if threads[botId] == nil {
            threads[botId] = ThreadData(threadId: bots[idx].threadId)
        }
        save()
        return task
    }

    public func selectTask(botId: String, taskId: String?) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let taskId, let task = bots[idx].tasks.first(where: { $0.id == taskId }) {
            bots[idx].activeTaskId = taskId
            bots[idx].threadId = task.threadId
            if threads[taskId] == nil {
                threads[taskId] = ThreadData(threadId: task.threadId)
            }
        } else {
            bots[idx].activeTaskId = nil
        }
        save()
    }

    public func messagesForActiveContext(botId: String) -> [ThreadMessage] {
        guard let bot = bots.first(where: { $0.id == botId }) else { return [] }
        if let taskId = bot.activeTaskId {
            return threads[taskId]?.messages ?? []
        }
        return threads[botId]?.messages ?? []
    }

    public func toggleReaction(botId: String, messageId: String, emoji: String) {
        let key: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var reactions = thread.messages[mIdx].reactions
        if let rIdx = reactions.firstIndex(where: { $0.emoji == emoji }) {
            reactions[rIdx].count += 1
            if reactions[rIdx].count > 3 {
                reactions.remove(at: rIdx)
            }
        } else {
            reactions.append(MessageReaction(emoji: emoji))
        }
        thread.messages[mIdx].reactions = reactions
        threads[key] = thread
        save()
    }

    public func answerApproval(botId: String, messageId: String, decision: ApprovalDecision) {
        let key = threadKey(for: botId)
        guard var thread = threads[key],
              let mIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        for i in thread.messages[mIdx].blocks.indices {
            if case .approval(let tool, let detail, _) = thread.messages[mIdx].blocks[i] {
                let status: ApprovalStatus
                switch decision {
                case .allow: status = .allowed
                case .deny: status = .denied
                case .alwaysAllow:
                    status = .alwaysAllowed
                    if let bIdx = bots.firstIndex(where: { $0.id == botId }) {
                        if !bots[bIdx].alwaysAllowTools.contains(tool) {
                            bots[bIdx].alwaysAllowTools.append(tool)
                        }
                    }
                }
        thread.messages[mIdx].blocks[i] = .approval(tool: tool, detail: detail, status: status)
            }
        }
        let pending = thread.pendingTool
        thread.pendingTool = nil
        if decision == .deny {
            let follow = ThreadMessage(
                id: Ids.new(),
                threadId: thread.threadId,
                seq: thread.nextSeq,
                role: .bot,
                blocks: [.text("okay — cancelled.")]
            )
            thread.messages.append(follow)
            thread.cursor = follow.seq
            if thread.run?.status == .waitingInput {
                thread.run?.status = .completed
                thread.run?.completedAt = .now
            }
            threads[key] = thread
            if let idx = bots.firstIndex(where: { $0.id == botId }) {
                bots[idx].status = "idle"
            }
            save()
            releaseWorkingFolderOverrideIfNeeded(botId: botId)
            return
        }
        threads[key] = thread
        save()
        if let pending {
            Task { [weak self] in
                guard let self else { return }
                let dummy = ModelEndpoint(
                    provider: "injected",
                    model: "local",
                    baseURL: "https://localhost/v1",
                    apiKey: "local"
                )
                let result = await self.executeAgentTool(
                    name: pending.name,
                    argumentsJSON: pending.arguments,
                    botId: botId,
                    depth: 0,
                    endpoint: dummy,
                    client: self.chatCompleter
                        ?? Self.defaultClient(for: self.bots.first(where: { $0.id == botId })?.modelProvider
                            ?? self.modelProvider),
                    approved: true
                )
                self.send(
                    botId: botId,
                    text: "Approved \(pending.tool). Tool result:\n\(result.output)\nContinue the task."
                )
            }
            return
        }
        let follow = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text("okay — proceeding.")]
        )
        thread.messages.append(follow)
        thread.cursor = follow.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    public func answerChoice(botId: String, messageId: String, option: ChoiceOption) {
        let key = threadKey(for: botId)
        guard var thread = threads[key] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(option.label)]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        threads[key] = thread
        save()
        send(botId: botId, text: option.label)
        _ = messageId
    }

    public func regenerateLast(botId: String) {
        regenerateFrom(botId: botId, messageId: nil)
    }

    /// Drop replies after a user (or bot) message and run again from that prompt.
    public func regenerateFrom(botId: String, messageId: String?) {
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return }
        let user: ThreadMessage?
        if let messageId, let match = thread.messages.first(where: { $0.id == messageId }) {
            if match.role == .user {
                user = match
            } else {
                user = thread.messages.last(where: { $0.seq < match.seq && $0.role == .user })
            }
        } else {
            user = thread.messages.last(where: { $0.role == .user })
        }
        guard let user else { return }
        if let idx = thread.messages.firstIndex(where: { $0.id == user.id }) {
            thread.messages.removeSubrange((idx + 1)...)
            thread.llmMessages = []
            thread.pendingTool = nil
            threads[key] = thread
            save()
        }
        launchRun(botId: botId, threadKey: key, prompt: user.firstText)
    }

    /// Remove the last user prompt and everything after it. Returns the restored draft.
    @discardableResult
    public func undoSend(botId: String) -> String? {
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return nil }
        guard let lastUserIdx = thread.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let text = thread.messages[lastUserIdx].firstText
        thread.messages.removeSubrange(lastUserIdx...)
        thread.llmMessages = []
        thread.pendingTool = nil
        thread.run = nil
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
            bots[idx].preview = thread.messages.last?.firstText ?? ""
            bots[idx].updatedAt = .now
        }
        save()
        pendingComposerText = text
        return text
    }

    public func canUndoSend(botId: String) -> Bool {
        threads[threadKey(for: botId)]?.messages.contains(where: { $0.role == .user }) == true
    }

    public func editUserMessage(botId: String, messageId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = threadKey(for: botId)
        stopRun(botId: botId)
        guard var thread = threads[key] else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId && $0.role == .user }) else { return }
        thread.messages[idx].blocks = [.text(trimmed)]
        thread.messages.removeSubrange((idx + 1)...)
        thread.llmMessages = []
        thread.pendingTool = nil
        threads[key] = thread
        if let botIdx = bots.firstIndex(where: { $0.id == botId }) {
            bots[botIdx].preview = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        }
        save()
        launchRun(botId: botId, threadKey: key, prompt: trimmed)
    }

    @discardableResult
    public func branchFromMessage(botId: String, messageId: String) -> BotTask? {
        let key = threadKey(for: botId)
        guard let source = threads[key] else { return nil }
        guard let cut = source.messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        let prefix = Array(source.messages.prefix(through: cut))
        let title = prefix.last(where: { $0.role == .user })?.firstText ?? "Branch"
        guard let task = createTask(botId: botId, title: String(title.prefix(48))) else { return nil }
        if var branched = threads[task.id] {
            branched.messages = prefix.map { message in
                var copy = message
                copy.threadId = branched.threadId
                return copy
            }
            branched.llmMessages = []
            threads[task.id] = branched
            save()
        }
        return task
    }

    public func openChatSearch() { chatSearchOpen = true }
    public func closeChatSearch() {
        chatSearchOpen = false
        highlightMessageId = nil
    }

    public func jumpToSearchHit(_ hit: ChatSearchHit) {
        if let groupId = hit.groupId {
            activeGroupId = groupId
            activeBotId = nil
            mainView = .chat
        } else if let botId = hit.botId {
            activeGroupId = nil
            selectBot(botId)
            if hit.threadKey != botId {
                selectTask(botId: botId, taskId: hit.threadKey)
            } else {
                selectTask(botId: botId, taskId: nil)
            }
        }
        highlightMessageId = hit.messageId
        chatSearchOpen = false
    }

    public func searchChats(query: String, currentThreadOnly: Bool) -> [ChatSearchHit] {
        let scope: ChatSearch.Scope = {
            if currentThreadOnly, let key = activeSessionKey { return .thread(key) }
            return .all
        }()
        return ChatSearch.hits(query: query, bots: bots, groups: groups, threads: threads, scope: scope)
    }

    /// When set, routine ticks skip UI navigation and the app may terminate after background runs finish.
    public var headlessRoutineTick = false

    public func waitForPluginTasks() async {
        let tasks = Array(pluginTasks.values)
        for task in tasks {
            _ = await task.result
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Wait for a condition, counting scheduling opportunities rather than
    /// elapsed time.
    ///
    /// Wall clock is the wrong clock for these helpers. `AppStore` is
    /// `@MainActor`, the test suites run in parallel against that one actor,
    /// and under contention several seconds can pass before a continuation is
    /// scheduled at all — while the work being awaited is milliseconds (tests
    /// build stores with `delayScale: 0.01`). A wall-clock deadline therefore
    /// failed tests that were not broken, and did so more often the more of
    /// the suite ran alongside them.
    ///
    /// Counting polls scales with load instead: the producer gets the same
    /// number of chances to run on an idle machine and a saturated one.
    /// `timeout` expresses that budget as the time it would take when idle.
    /// The absolute cap exists only so a genuine deadlock still ends the run
    /// rather than hanging the suite.
    private func poll(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        if condition() { return true }
        let attempts = max(1, Int((timeout / Self.pollInterval).rounded()))
        let hardDeadline = Date().addingTimeInterval(Self.pollHardCap)
        for _ in 0 ..< attempts {
            try? await Task.sleep(for: .milliseconds(20))
            if condition() { return true }
            if Date() > hardDeadline { break }
        }
        return condition()
    }

    private static let pollInterval: TimeInterval = 0.02
    private static let pollHardCap: TimeInterval = 240

    /// Await the task owning the thread's current run, following the chain
    /// when one run starts a follow-up (approving a tool continues into a new
    /// run).
    ///
    /// Every run is registered in `runTasks` in the same synchronous step that
    /// publishes it on the thread, and `runAgent` clears its entry before
    /// returning — so a run visible here always has its task, and awaiting
    /// that task means the run's status is final. No polling window to lose.
    private func drainRuns(for key: String) async {
        var awaited = Set<String>()
        while let run = threads[key]?.run, run.status.isActive {
            guard let task = runTasks[run.id], awaited.insert(run.id).inserted else { break }
            _ = await task.value
        }
    }

    public func waitForRunStatus(botId: String, status: RunStatus, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        return await poll(timeout: timeout) { self.threads[key]?.run?.status == status }
    }

    public func waitForPendingTool(botId: String, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        return await poll(timeout: timeout) { self.threads[key]?.pendingTool != nil }
    }

    public func waitForRunCompletion(botId: String, timeout: TimeInterval = 15) async -> Bool {
        let key = threadKey(for: botId)
        await drainRuns(for: key)
        guard let run = threads[key]?.run else { return true }
        if !run.status.isActive { return run.status == .completed }
        // Still active with no task of its own to await — another path owns it.
        _ = await poll(timeout: timeout) { self.threads[key]?.run?.status.isActive != true }
        return threads[key]?.run?.status == .completed
    }

    public func waitForComputerState(botId: String, state: ComputerState, timeout: TimeInterval = 10) async -> Bool {
        if computers[botId]?.state == state { return true }
        // `boot` publishes its task synchronously, so awaiting it is exact.
        if let task = bootTasks[botId] {
            _ = await task.value
            if computers[botId]?.state == state { return true }
        }
        // Other transitions — `takeControl`, or a run opening the computer
        // surface mid-turn — are not a single awaitable task.
        return await poll(timeout: timeout) { self.computers[botId]?.state == state }
    }

    public func waitForActiveRuns(timeout: TimeInterval = 120) async {
        let attempts = max(1, Int((timeout / Self.pollInterval).rounded()))
        let hardDeadline = Date().addingTimeInterval(Self.pollHardCap)
        for _ in 0 ..< attempts {
            // Awaiting the tracked tasks is the real wait: each returns only
            // after `runAgent` has finalized its run and cleared its entry.
            for task in Array(runTasks.values) {
                _ = await task.result
            }
            if runTasks.isEmpty,
               !threads.values.contains(where: { $0.run?.status.isActive == true }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
            if Date() > hardDeadline { return }
        }
    }

    public func appendRunLog(botId: String, kind: String, text: String) {
        runLog = RunLog.appending(runLog, botId: botId, kind: kind, text: text)
    }

    public func lastRunLogText() -> String {
        RunLog.dump(runLog)
    }

    public func clearSecret(_ secret: AppSecret) {
        var config = appConfig
        config.clearSecret(secret)
        saveAppConfig(config)
    }

    public func applySecret(_ secret: AppSecret, input: String) {
        var config = appConfig
        config.applySecret(secret, input: input)
        saveAppConfig(config)
        if secret == .composioConnect || secret == .composioApi {
            Task { await refreshPluginCatalog() }
        }
    }

    @discardableResult
    public func importWorkspaceJSON(_ data: Data) -> Bool {
        guard var ws = try? userPersistence.decodeJSON(UserWorkspace.self, from: data) else { return false }
        if let userId = session?.userId {
            let imported = WorkspaceSecrets.from(workspace: ws)
            if !imported.isEmpty {
                if var existing = SecretStore.load(userId: userId) {
                    if imported.apiKey != nil { existing.apiKey = imported.apiKey }
                    if imported.oauthJSON != nil { existing.oauthJSON = imported.oauthJSON }
                    if !imported.providerCredentials.isEmpty {
                        existing.providerCredentials.merge(imported.providerCredentials) { _, n in n }
                    }
                    if !imported.connectionSecrets.isEmpty {
                        existing.connectionSecrets.merge(imported.connectionSecrets) { _, n in n }
                    }
                    if imported.composioConnectKey != nil { existing.composioConnectKey = imported.composioConnectKey }
                    if imported.composioApiKey != nil { existing.composioApiKey = imported.composioApiKey }
                    if imported.googleClientId != nil { existing.googleClientId = imported.googleClientId }
                    if imported.googleClientSecret != nil { existing.googleClientSecret = imported.googleClientSecret }
                    if imported.boxToken != nil { existing.boxToken = imported.boxToken }
                    if imported.ttsKey != nil { existing.ttsKey = imported.ttsKey }
                    if imported.sentryDSN != nil { existing.sentryDSN = imported.sentryDSN }
                    if imported.braveSearchKey != nil { existing.braveSearchKey = imported.braveSearchKey }
                    try? SecretStore.save(existing, userId: userId)
                } else {
                    try? SecretStore.save(imported, userId: userId)
                }
                ws = imported.stripped(from: ws)
            } else if let existing = SecretStore.load(userId: userId) {
                ws = existing.applying(to: ws)
            }
        }
        for (_, task) in runTasks { task.cancel() }
        runTasks.removeAll()
        applyWorkspace(ws)
        route = bots.isEmpty ? .onboarding : .shell
        save()
        return true
    }

    @discardableResult
    public func writeWorkspaceBackup(to directory: URL? = nil) -> URL? {
        guard let data = exportWorkspaceJSON() else { return nil }
        let dir = directory ?? WorkspaceBackup.backupDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(WorkspaceBackup.filename())
        do {
            try data.write(to: url, options: .atomic)
            appendRunLog(botId: activeBotId ?? "workspace", kind: "backup", text: url.path)
            return url
        } catch {
            return nil
        }
    }

    public func diagnosticsDirectory() -> URL {
        userPersistence.diagnosticsDirectory
    }

    public func deleteGroup(_ groupId: String) {
        groups.removeAll { $0.id == groupId }
        threads.removeValue(forKey: groupId)
        if activeGroupId == groupId {
            activeGroupId = nil
            activeBotId = visibleBots.first?.id
        }
        save()
    }

    public var allRoutines: [Routine] {
        routines.values.flatMap { $0 }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    public func setRoutineActive(_ routineId: String, active: Bool) {
        for botId in routines.keys {
            guard let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }) else { continue }
            routines[botId]?[idx].active = active
            save()
            return
        }
    }

    public func setDraft(threadKey: String, text: String) {
        composerDrafts[threadKey] = text
    }

    public func draft(for threadKey: String) -> String {
        composerDrafts[threadKey] ?? ""
    }

    public func selectBotByIndex(_ index: Int) {
        let list = visibleBots
        guard list.indices.contains(index) else { return }
        selectBot(list[index].id)
    }

    public func selectAdjacentBot(delta: Int) {
        let list = visibleBots
        guard !list.isEmpty else { return }
        let current = list.firstIndex(where: { $0.id == activeBotId }) ?? 0
        let next = (current + delta + list.count) % list.count
        selectBot(list[next].id)
    }

    public var missedRoutineCount: Int {
        routines.values.flatMap { $0 }.filter { routine in
            guard let next = routine.nextRunAt else { return false }
            return routine.active && next < Date.now.addingTimeInterval(-12 * 3600)
        }.count
    }
}
