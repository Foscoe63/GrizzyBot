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
    @State var panelSize = AppSettingsPanelMetrics.saved
    @State var resizeOrigin: CGSize?

    var body: some View {
        GeometryReader { geo in
            let bounds = CGSize(width: geo.size.width, height: geo.size.height)
            let fitted = AppSettingsPanelMetrics.clamped(panelSize, in: bounds)
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { store.closeAppSettings() }

                HStack(spacing: 0) {
                    nav
                    content
                }
                .frame(width: fitted.width, height: fitted.height)
                .background(Theme.bgRightPanel)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                }
                .overlay(alignment: .trailing) {
                    resizeStrip(axis: .width, bounds: bounds)
                }
                .overlay(alignment: .bottom) {
                    resizeStrip(axis: .height, bounds: bounds)
                }
                .overlay(alignment: .bottomTrailing) {
                    resizeGrip(bounds: bounds)
                }
                .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
                .accessibilityIdentifier(OverlayA11y.settings)
                .accessibilityElement(children: .contain)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityIdentifier(OverlayA11y.settings)
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

    enum ResizeAxis {
        case width, height, both
    }

    func resizeStrip(axis: ResizeAxis, bounds: CGSize) -> some View {
        let vertical = axis == .height
        return Color.clear
            .frame(width: vertical ? nil : 8, height: vertical ? 8 : nil)
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(axis: axis, bounds: bounds))
            .onHover { hovering in
                guard hovering else {
                    NSCursor.arrow.set()
                    return
                }
                if vertical {
                    NSCursor.frameResize(position: .bottom, directions: [.inward, .outward]).set()
                } else {
                    NSCursor.frameResize(position: .right, directions: [.inward, .outward]).set()
                }
            }
            .accessibilityHidden(true)
    }

    func resizeGrip(bounds: CGSize) -> some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                var path = Path()
                let offset = CGFloat(5 + i * 4)
                path.move(to: CGPoint(x: size.width - 1, y: size.height - offset))
                path.addLine(to: CGPoint(x: size.width - offset, y: size.height - 1))
                ctx.stroke(path, with: .color(Theme.textMuted.opacity(0.7)), lineWidth: 1.4)
            }
        }
        .frame(width: 16, height: 16)
        .padding(10)
        .contentShape(Rectangle())
        .highPriorityGesture(resizeGesture(axis: .both, bounds: bounds))
        .onHover { hovering in
            if hovering {
                NSCursor.frameResize(position: .bottomRight, directions: [.inward, .outward]).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to resize")
        .accessibilityLabel("Resize settings")
        .accessibilityAddTraits(.isButton)
    }

    func resizeGesture(axis: ResizeAxis, bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = AppSettingsPanelMetrics.clamped(panelSize, in: bounds)
                }
                guard let origin = resizeOrigin else { return }
                var next = origin
                if axis != .height {
                    next.width = origin.width + value.translation.width
                }
                if axis != .width {
                    next.height = origin.height + value.translation.height
                }
                panelSize = AppSettingsPanelMetrics.clamped(next, in: bounds)
            }
            .onEnded { _ in
                resizeOrigin = nil
                AppSettingsPanelMetrics.save(panelSize)
            }
    }

    var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textBright)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)

            ForEach(AppStore.AppSettingsSection.allCases) { section in
                Button {
                    store.appSettingsSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sectionIcon(section))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textLetter)
                            .frame(width: 16)
                        Text(section.label)
                            .font(.system(size: 14))
                            .foregroundStyle(
                                store.appSettingsSection == section ? Theme.textBright : Theme.textSecondary
                            )
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        store.appSettingsSection == section ? Theme.bgHoverRow : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 190)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.borderMainHdr).frame(width: 1)
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.appSettingsSection.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                Button {
                    store.closeAppSettings()
                } label: {
                    Text("✕")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textMuted)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.appSettingsSection {
                    case .general:
                        generalSection

                    case .connections:
                        connectionsSection

                    case .computer:
                        computerSection

                    case .voice:
                        voiceSection

                    case .tools:
                        toolsSection

                    case .themes:
                        themesSection

                    case .privacy:
                        privacySection

                    case .watchers:
                        watchersSection

                    case .diagnostics:
                        diagnosticsSection

                    case .governance:
                        GovernanceSettingsView()

                    case .knowledge:
                        KnowledgeSettingsView()

                    case .components:
                        ComponentsSettingsView()

                    case .folders:
                        FoldersSettingsView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .grizzyScroll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            content()
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
        }
    }

    func secretRow(
        title: String,
        configured: Bool,
        text: Binding<String>,
        onClear: (() -> Void)? = nil
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
            GrizzyField(placeholder: configured ? "•••••••• (leave blank to keep)" : "Paste key", text: text, secure: true)
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

private enum AppSettingsPanelMetrics {
    static let minWidth: CGFloat = 720
    static let minHeight: CGFloat = 480
    static let defaultSize = CGSize(width: 860, height: 560)
    private static let widthKey = "grizzy.settingsPanel.width"
    private static let heightKey = "grizzy.settingsPanel.height"

    static var saved: CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: widthKey)
        let height = defaults.double(forKey: heightKey)
        if width < minWidth || height < minHeight {
            return defaultSize
        }
        return CGSize(width: width, height: height)
    }

    static func save(_ size: CGSize) {
        UserDefaults.standard.set(size.width, forKey: widthKey)
        UserDefaults.standard.set(size.height, forKey: heightKey)
    }

    static func clamped(_ size: CGSize, in bounds: CGSize) -> CGSize {
        var width = max(size.width, minWidth)
        var height = max(size.height, minHeight)
        if bounds.width > 1 {
            width = min(width, max(bounds.width - 32, 320))
        }
        if bounds.height > 1 {
            height = min(height, max(bounds.height - 32, 320))
        }
        return CGSize(width: width, height: height)
    }
}
