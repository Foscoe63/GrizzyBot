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
    case library
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
    /// Bot-to-bot handoffs made with `message_bot`, oldest first.
    public var botChat: [BotChatEntry] = []
    public var appConfig: AppConfig = AppConfig()
    public var customTools: [CustomAgentTool] = []
    public var mcpServers: [McpServer] = []
    public var actionPolicy: ActionPolicy = .openDefault
    public var knowledgeSources: [KnowledgeSource] = []
    /// Latest "N indexed, M skipped" numbers per folder source. Not persisted.
    public var knowledgeStats: [String: KnowledgeIndexStats] = [:]
    @ObservationIgnored let knowledgeIndexer = KnowledgeIndexer()
    public var grantedFolders: [GrantedFolder] = []
    public var pluginGrants: [PluginGrant] = []
    public var sandboxComponents: [SandboxComponent] = []
    public var mcpAdvertisedTools: [String: [String]] = [:]
    /// Session cache of Toolport/MacUse catalog tools promoted to first-class ChatTools.
    public var mcpPromotedTools: [String: McpPromotedTool] = [:]
    /// Live MCP connection probes (not persisted).
    public var mcpProbeStatus: [String: McpProbeStatus] = [:]
    /// Last successful `tools/list` payloads for UI subtitles (not persisted).
    public var mcpListedTools: [String: [McpToolInfo]] = [:]
    var mcpProbeGeneration: [String: UInt64] = [:]
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
    /// Text to quote into the reply box (⌘L on a selection, or Quote on a message).
    public var pendingQuote: String?
    /// Prefills Sign in when the user picks an existing account on Welcome.
    public var pendingAuthEmail: String = ""

    public enum AppSettingsSection: String, Sendable, CaseIterable, Identifiable {
        case general, connections, computer, voice, tools, themes, privacy, watchers, diagnostics, governance, knowledge, components, folders
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
            case .folders: return "Folders"
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
    /// Called when a run stops for an approval, so the app can raise a notification with Allow / Deny.
    public var onApprovalNeeded: ((Bot, _ tool: String, _ detail: String) -> Void)?
    public var editingRoutineId: String? = nil
    public var routineDraft: RoutineDraft = RoutineDraft()

    public var connectionPending: Set<String> = []

    public var pluginsUseOAuth: Bool {
        composioClient != nil || appConfig.composioConfigured
    }

    public var googlePluginsReady: Bool {
        googleOAuthClient != nil || appConfig.googleOAuthConfigured
    }

    func liveComposio() -> (any ComposioConnecting)? {
        if let composioClient { return composioClient }
        let key = (appConfig.composioConnectKey ?? appConfig.composioApiKey ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return ComposioClient(connectKey: key, apiKey: appConfig.composioApiKey)
    }

    func liveGoogleOAuth() -> (any GoogleOAuthConnecting)? {
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
    static func browserOpenableURL(_ url: URL) -> URL? {
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

    var users: [UserAccount] = []
    let globalRoot: URL
    var globalPersistence: Persistence
    var userPersistence: Persistence
    var botHome: BotHomeStore
    var destinations: DestinationStore
    var canvasBoard: CanvasBoardStore
    var artifactStore: ArtifactStore
    var runTasks: [String: Task<Void, Never>] = [:]
    /// Mid-run messages the agent loop picks up between steps, keyed by run.
    var runInboxes: [String: RunInbox] = [:]
    /// Messages waiting for their run to end before they get a turn, keyed by thread.
    var heldSends: [String: [QueuedSend]] = [:]
    /// Loopback receiver that lets outside systems fire routines.
    let webhookReceiver = WebhookReceiver()
    /// Loopback MCP server that lets Claude Desktop / Cursor / Claude Code drive the bots.
    let controlPlane = ControlPlaneServer()
    /// Ships run and tool spans to an OpenTelemetry collector when one is configured.
    let traceExporter = TraceExporter()
    /// Phone-friendly web companion.
    let companionServer = CompanionServer()
    /// Outside-content taint a bot's next run starts with, because the bot that handed it work had read
    /// outside content. Consumed by that run.
    var inheritedTaint: [String: [String]] = [:]
    /// What tainted each bot's most recent run, so a room can pass it along when one bot pulls in another.
    var lastRunTaint: [String: [String]] = [:]
    /// The Chief of Staff's in-flight hand-off, so Stop can end it.
    var dispatchTasks: [String: Task<Void, Never>] = [:]
    /// The bot a dispatch is waiting on, per Chief of Staff.
    var dispatchPeers: [String: String] = [:]
    /// Sends that arrived while a routing decision was being made, replayed in order afterwards.
    var routingHolds: [String: [HeldSend]] = [:]
    var routingInFlight: Set<String> = []
    /// Routing decisions for rooms that have not started their turns yet.
    var roomRoutingInFlight = 0
    /// Reads `op://` references saved as secrets. Replaceable so tests never call the real tool.
    public var secretReader: any SecretReferenceReading = OnePasswordCLI()
    /// When each webhook last fired, to keep a chatty sender from flooding a bot.
    var webhookLastFire: [String: Date] = [:]
    /// Long-poll loop for Telegram while it is switched on.
    var telegramTask: Task<Void, Never>?
    var telegramPairing = TelegramPairing()
    /// Chats waiting on a reply, keyed by the bot they asked.
    var telegramReplyTargets: [String: Int64] = [:]
    /// Builds the API client from a token. Tests swap it for a stand-in.
    var telegramAPIFactory: @Sendable (String) -> any TelegramAPI = { TelegramBotAPI(token: $0) }
    /// Last thing worth telling the person about the Telegram link, for Settings.
    public var telegramNotice: String?
    var bootTasks: [String: Task<Void, Never>] = [:]
    var pluginTasks: [String: Task<Void, Never>] = [:]
    var schedulerTask: Task<Void, Never>?

    /// Shorter delays in tests so `swift test` stays fast.
    public var delayScale: Double = 1.0
    /// How long a waiting `message_bot` gives a peer before handing the turn
    /// back with "still working". Tests lower it to exercise that path.
    public var peerReplyTimeout: TimeInterval = 120
    /// How long a bot may work on a job another bot handed it before it is stopped and the lead is
    /// told. Waiting on the person for an approval does not count. 0 turns the limit off.
    public var delegateTimeout: TimeInterval = 20 * 60
    public internal(set) var delegateTimers: [String: Task<Void, Never>] = [:]
    /// Tools lent to a bot for the one job it was handed (see `DelegateTools`).
    var lentToolRecords: [String: LentTools] = [:]
    /// Watcher runs pin file tools to the watch path until the run goes idle.
    var runWorkingFolderOverride: [String: String] = [:]
    /// Bot currently executing a watcher-triggered run (for echo suppression).
    var watcherRunByBotId: [String: String] = [:]
    /// This store's own watchers. Not a singleton: two stores — two tests, or
    /// two workspaces — would otherwise share FSEvent streams and suppression
    /// state for directories that have nothing to do with each other.
    ///
    /// ObservationIgnored because this is machinery, not state a view renders;
    /// the @Observable macro rewrites stored properties and does not accept it
    /// otherwise.
    @ObservationIgnored let folderWatcherService = FolderWatcherService()
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
    var providerCredentials: [String: ProviderCredential] = [:]
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
    static let localEmail = "local@grizzybot.local"
    static let localName = "Local User"

    func bootstrap() {
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
    func ensureLocalSession() {
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

    func attachUserPersistence(userId: String) {
        let userDir = AccountLayout.ensureUserDirectory(global: globalRoot, userId: userId)
        userPersistence = Persistence(root: userDir)
        botHome = BotHomeStore(root: userDir)
        destinations = DestinationStore(root: userDir)
    }

    func enterSession(_ session: Session) {
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

    func loadWorkspace(for userId: String) {
        applyWorkspace(userPersistence.loadWorkspace(userId: userId))
    }

    func clearWorkspaceState() {
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
        botChat = []
        customTools = []
        mcpServers = []
        folderWatchers = []
        grantedFolders = []
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

    func applyWorkspace(_ ws: UserWorkspace) {
        bots = ws.bots
        threads = ws.threads
        for key in threads.keys { threads[key]?.cancelOrphanedApprovals() }
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
        botChat = ws.botChat
        grantedFolders = ws.grantedFolders
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
        grantImpliedTools()
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

    func currentWorkspace() -> UserWorkspace {
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
            mcpAdvertisedTools: mcpAdvertisedTools,
            botChat: botChat,
            grantedFolders: grantedFolders
        )
    }

    func currentGovernance() -> GovernanceBundle {
        GovernanceBundle(
            actionPolicy: actionPolicy,
            pluginGrants: pluginGrants,
            knowledgeSources: knowledgeSources,
            sandboxComponents: sandboxComponents,
            mcpAdvertisedTools: mcpAdvertisedTools
        )
    }

    func applyGovernance(_ bundle: GovernanceBundle) {
        actionPolicy = bundle.actionPolicy
        pluginGrants = bundle.pluginGrants
        knowledgeSources = bundle.knowledgeSources
        sandboxComponents = bundle.sandboxComponents
        mcpAdvertisedTools = bundle.mcpAdvertisedTools
    }

    func saveGovernanceIfOwner() {
        guard isOwner else { return }
        globalPersistence.saveGovernance(currentGovernance())
    }

    func save() {
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

    func syncActiveProviderFields() {
        guard let provider = modelProvider else { return }
        let settings = modelProviderSettings(for: provider)
        modelId = settings.modelId
        modelBaseUrl = settings.baseUrl
        fetchedModels = settings.fetchedModels
        apiKey = settings.apiKey
        oauthJSON = settings.oauthJSON
    }

    func sleep(_ seconds: Double) async {
        let scaled = max(0.001, seconds * delayScale)
        try? await Task.sleep(for: .seconds(scaled))
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
            enabledTools: toolIds(for: template)
        )
    }

    /// The template's built-in tools plus its MCP tools, resolved against the
    /// servers configured in this workspace (matched by name, case-insensitive).
    public func toolIds(for template: BotTemplate) -> [String] {
        var ids = template.toolIds
        for (name, tools) in template.mcpTools.sorted(by: { $0.key < $1.key }) {
            guard let server = mcpServers.first(where: { $0.name.lowercased() == name }) else { continue }
            ids.append(server.toolId)
            ids.append(contentsOf: McpToolGate.childIds(serverId: server.id, names: tools))
        }
        return ids
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







    func announceFinished(botId: String, text: String, status: RunStatus?) {
        guard status == .completed else { return }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        onRunFinished?(bot, cleaned)
    }

    func upsertFile(path: String, content: String) {
        if let idx = files.firstIndex(where: { $0.first == path }) {
            files[idx] = [path, content]
        } else {
            files.append([path, content])
        }
    }

    /// Why the last workspace import or backup failed, for the Settings notice. Nil after a success.
    public var lastWorkspaceError: String?
    /// A team waiting for the person to review it. Every way of opening a team (file, link, drop,
    /// library) lands here, and nothing is created until they confirm.
    public var pendingTeamPackage: TeamPackage?
    /// Recent router-model decisions and timings (see `RoutingMemory`).
    public var routingMemory = RoutingMemory()
    /// When each bot's failed runs were last reported to the Chief of Staff (see `TeamIncidents`).
    var incidentHistory: [String: [Date]] = [:]

    /// When set, routine ticks skip UI navigation and the app may terminate after background runs finish.
    public var headlessRoutineTick = false
}
