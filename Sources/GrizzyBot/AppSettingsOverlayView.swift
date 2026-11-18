import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

/// App settings modal: General / Connections / Computer / Voice.
struct AppSettingsOverlayView: View {
    @Environment(AppStore.self) var store
    @State var profileName = ""
    @State var profileEmail = ""
    @State var composioConnect = ""
    @State var composioApi = ""
    @State var googleClientId = ""
    @State var googleClientSecret = ""
    @State var googleSetupExpanded = false
    @State var boxToken = ""
    @State var braveSearchKey = ""
    @State var ttsKey = ""
    @State var sentryDSN = ""
    @State var memoryProbe: AiMemoryBridge.Probe?
    @State var memoryChecking = false
    @State var ttsVoice = "Rachel"
    @State var computerMode: ComputerMode = .auto
    @State var mcpName = ""
    @State var mcpTransport: McpTransport = .stdio
    @State var mcpCommand = ""
    @State var mcpArgs = ""
    @State var mcpEnv = ""
    @State var mcpUrl = ""
    @State var mcpHeaders = ""
    @State var editingMcpId: String?
    @State var addMcpOpen = false
    @State var snapshotName = ""
    @State var confirmWipeWorkspace = false
    @State var confirmResetAllTokens = false
    @State var sessionNotice: String?
    @State var bonjourHits: [MCPBonjourDiscovery.Entry] = []
    @State var gatewayPort = "8787"
    @State var gatewayKey = ""
    @State var railQuery = ""

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgMain)
        .accessibilityIdentifier(OverlayA11y.settings)
        .accessibilityElement(children: .contain)
        .onAppear(perform: load)
        .onChange(of: store.appSettingsSection) { _, section in
            if section == .tools { store.probeAllMcpServers() }
        }
        .alert("Delete this workspace?", isPresented: $confirmWipeWorkspace) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                store.deleteWorkspace()
                store.closeAppSettings()
            }
        } message: {
            Text("Removes every bot, chat, routine, and file. Your account stays. Snapshots are kept until you delete them.")
        }
        .alert("Reset token counters for every bot?", isPresented: $confirmResetAllTokens) {
            Button("Cancel", role: .cancel) {}
            Button("Reset all", role: .destructive) {
                store.resetChatTokens()
            }
        } message: {
            Text("Prompt, Sent, and Recv go back to zero on every bot. Chat messages stay. Sidebar weekly usage uses the same ledger.")
        }
        .alert("Session", isPresented: Binding(
            get: { sessionNotice != nil },
            set: { if !$0 { sessionNotice = nil } }
        )) {
            Button("OK", role: .cancel) { sessionNotice = nil }
        } message: {
            Text(sessionNotice ?? "")
        }
    }

    private var railSections: [AppStore.AppSettingsSection] {
        let q = railQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return AppStore.AppSettingsSection.allCases.filter { q.isEmpty || $0.label.lowercased().contains(q) }
    }

    var rail: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                TextField("Search", text: $railQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textBright)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.bgChip)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(AppStore.AppSettingsSection.railGroups, id: \.self) { group in
                        let items = railSections.filter { $0.railGroup == group }
                        if !items.isEmpty {
                            Text(group)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            ForEach(items) { section in railButton(section) }
                        }
                    }
                }
            }
            .grizzyScroll()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .padding(.bottom, 12)
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.borderMainHdr).frame(width: 1)
        }
    }

    func railButton(_ section: AppStore.AppSettingsSection) -> some View {
        let selected = store.appSettingsSection == section
        return Button {
            store.appSettingsSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sectionIcon(section))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Theme.textBright : Theme.textLetter)
                    .frame(width: 18)
                Text(section.label)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.textBright : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Theme.bgSelectedRow : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.appSettingsSection.label)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                    .padding(.top, 52)
                    .padding(.bottom, 14)
                sectionBody
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .grizzyScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                store.closeAppSettings()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close settings")
            .padding(.top, 14)
            .padding(.trailing, 18)
        }
    }

    @ViewBuilder
    var sectionBody: some View {
        switch store.appSettingsSection {
        case .general: generalSection
        case .connections: connectionsSection
        case .computer: computerSection
        case .voice: voiceSection
        case .tools: toolsSection
        case .themes: themesSection
        case .privacy: privacySection
        case .watchers: watchersSection
        case .diagnostics: diagnosticsSection
        case .governance: GovernanceSettingsView()
        case .knowledge: KnowledgeSettingsView()
        case .components: ComponentsSettingsView()
        case .folders: FoldersSettingsView()
        }
    }

    /// A flat settings group: heading, explanation, then its rows, closed by a hairline.
    func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 4)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
        }
    }

    func secretRow(
        title: String,
        configured: Bool,
        text: Binding<String>,
        onClear: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if configured {
                    Text("configured")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.green)
                    if let onClear {
                        Button("Clear") { onClear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.orange)
                    }
                }
            }
            GrizzyField(placeholder: configured ? "•••••••• (leave blank to keep)" : "Paste key, then press Return", text: text, secure: true, onCommit: onCommit)
        }
    }

    func sectionIcon(_ section: AppStore.AppSettingsSection) -> String {
        switch section {
        case .general: return "person.crop.circle"
        case .connections: return "link"
        case .computer: return "desktopcomputer"
        case .voice: return "waveform"
        case .tools: return "wrench.and.screwdriver"
        case .themes: return "paintpalette"
        case .privacy: return "hand.raised"
        case .watchers: return "clock"
        case .diagnostics: return "list.bullet.rectangle"
        case .governance: return "checkmark.shield"
        case .knowledge: return "books.vertical"
        case .components: return "puzzlepiece.extension"
        case .folders: return "folder"
        }
    }

    func load() {
        let config = store.appConfig
        profileName = config.profileName.isEmpty ? (store.session?.name ?? "") : config.profileName
        profileEmail = config.profileEmail.isEmpty ? (store.session?.email ?? "") : config.profileEmail
        computerMode = config.defaultComputerMode
        ttsVoice = config.ttsVoice ?? "Rachel"
        composioConnect = ""
        composioApi = ""
        googleClientId = ""
        googleClientSecret = ""
        boxToken = ""
        braveSearchKey = ""
        ttsKey = ""
        sentryDSN = ""
        gatewayPort = "\(config.localGateway.port)"
        gatewayKey = config.localGateway.apiKey
        if store.appSettingsSection == .tools {
            store.probeAllMcpServers()
        }
    }

    func persistProfile() {
        var config = store.appConfig
        config.profileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.profileEmail = profileEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveAppConfig(config)
    }

    func persistKeys() {
        store.applySecret(.composioConnect, input: composioConnect)
        store.applySecret(.composioApi, input: composioApi)
        store.applySecret(.box, input: boxToken)
        store.applySecret(.braveSearch, input: braveSearchKey)
        composioConnect = ""
        composioApi = ""
        boxToken = ""
        braveSearchKey = ""
    }

    func persistGoogleKeys() {
        store.applySecret(.googleClientId, input: googleClientId)
        store.applySecret(.googleClientSecret, input: googleClientSecret)
        googleClientId = ""
        googleClientSecret = ""
        if !store.appConfig.googleOAuthConfigured {
            googleSetupExpanded = true
        }
    }

    func persistVoice() {
        store.applySecret(.tts, input: ttsKey)
        var config = store.appConfig
        config.ttsVoice = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveAppConfig(config)
        ttsKey = ""
    }
}
