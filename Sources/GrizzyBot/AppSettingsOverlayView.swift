import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

/// App settings modal: General / Connections / Computer / Voice.
struct AppSettingsOverlayView: View {
    @Environment(AppStore.self) private var store
    @State private var profileName = ""
    @State private var profileEmail = ""
    @State private var composioConnect = ""
    @State private var composioApi = ""
    @State private var googleClientId = ""
    @State private var googleClientSecret = ""
    @State private var googleSetupExpanded = false
    @State private var boxToken = ""
    @State private var braveSearchKey = ""
    @State private var ttsKey = ""
    @State private var sentryDSN = ""
    @State private var ttsVoice = "Rachel"
    @State private var computerMode: ComputerMode = .auto
    @State private var mcpName = ""
    @State private var mcpTransport: McpTransport = .stdio
    @State private var mcpCommand = ""
    @State private var mcpArgs = ""
    @State private var mcpEnv = ""
    @State private var mcpUrl = ""
    @State private var mcpHeaders = ""
    @State private var editingMcpId: String?
    @State private var addMcpOpen = false
    @State private var snapshotName = ""
    @State private var confirmWipeWorkspace = false
    @State private var confirmResetAllTokens = false
    @State private var sessionNotice: String?
    @State private var bonjourHits: [MCPBonjourDiscovery.Entry] = []
    @State private var gatewayPort = "8787"
    @State private var gatewayKey = ""
    @State private var panelSize = AppSettingsPanelMetrics.saved
    @State private var resizeOrigin: CGSize?

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

    private enum ResizeAxis {
        case width, height, both
    }

    private func resizeStrip(axis: ResizeAxis, bounds: CGSize) -> some View {
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

    private func resizeGrip(bounds: CGSize) -> some View {
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

    private func resizeGesture(axis: ResizeAxis, bounds: CGSize) -> some Gesture {
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

    private var nav: some View {
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
                        Text(sectionIcon(section))
                            .font(.system(size: 13))
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

    private var content: some View {
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
                        settingsCard(
                            title: "Profile",
                            subtitle: "Shown in the sidebar. Saved when you leave a field."
                        ) {
                            GrizzyField(placeholder: "Your name", text: $profileName)
                            GrizzyField(placeholder: "you@example.com", text: $profileEmail)
                                .padding(.top, 8)
                        }
                        .onChange(of: profileName) { _, _ in persistProfile() }
                        .onChange(of: profileEmail) { _, _ in persistProfile() }

                        settingsCard(
                            title: "Background",
                            subtitle: "Routines run on a timer while GrizzyBot is open. Enable background routines to wake the app via a LaunchAgent (signed Release builds)."
                        ) {
                            Toggle("Show menu bar extra", isOn: Binding(
                                get: { store.appConfig.showMenuBar },
                                set: { value in
                                    var config = store.appConfig
                                    config.showMenuBar = value
                                    if !value { config.menuBarOnly = false }
                                    store.saveAppConfig(config)
                                    if !value { MainWindowController.applyMenuBarOnly(false) }
                                }
                            ))
                            .toggleStyle(.switch)
                            Toggle("Menu bar only", isOn: Binding(
                                get: { store.appConfig.menuBarOnly },
                                set: { value in
                                    var config = store.appConfig
                                    config.menuBarOnly = value
                                    if value { config.showMenuBar = true }
                                    store.saveAppConfig(config)
                                    MainWindowController.applyMenuBarOnly(value)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                            Text("When enabled, GrizzyBot launches to the menu bar. Use Open GrizzyBot to show the main window.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Launch at login", isOn: Binding(
                                get: { store.appConfig.launchAtLogin },
                                set: { value in
                                    var config = store.appConfig
                                    config.launchAtLogin = value
                                    store.saveAppConfig(config)
                                    _ = LoginItemController.setEnabled(value)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                            Text(LoginItemController.statusMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Background routines", isOn: Binding(
                                get: { store.appConfig.backgroundRoutines },
                                set: { value in
                                    var config = store.appConfig
                                    config.backgroundRoutines = value
                                    store.saveAppConfig(config)
                                    _ = RoutineAgentController.setEnabled(value)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                            #if DEBUG
                            Text("Launch at login and background routines require a signed Release build. SMAppService rejects ad-hoc Debug bundles.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                            #endif
                        }

                        settingsCard(
                            title: "Shared memory",
                            subtitle: "Every bot reads SHARED.md. Put standing rules under ## Pin. Agents remember with scope=shared."
                        ) {
                            GrizzyField(
                                placeholder: "Standing facts for the whole workspace",
                                text: Binding(
                                    get: { store.sharedMemory },
                                    set: { store.setSharedMemory($0) }
                                ),
                                axis: .vertical,
                                lineLimit: 4...10
                            )
                        }

                        settingsCard(
                            title: "Token counters",
                            subtitle: "Prompt, Sent, and Recv on the composer come from this bot’s billed usage. Reset them to start a session from zero. Chat messages are not deleted."
                        ) {
                            tokenCountersBody
                        }

                        settingsCard(
                            title: "Session",
                            subtitle: "Save a restore point, export the whole workspace, or wipe it. Backup uses the iCloud container when this build is team-signed, otherwise iCloud Drive’s GrizzyBot Backups folder, then Documents."
                        ) {
                            GrizzyField(label: "Snapshot name", placeholder: "Before experiments", text: $snapshotName)
                            HStack(spacing: 12) {
                                GrizzyButton(title: "Save snapshot", variant: .cream, size: .sm) {
                                    let meta = store.saveWorkspaceSnapshot(name: snapshotName)
                                    sessionNotice = meta.map { "Saved “\($0.name)”" } ?? "Could not save"
                                    snapshotName = ""
                                }
                                Button("Export workspace…") {
                                    guard let data = store.exportWorkspaceJSON() else { return }
                                    SessionFilePanel.save(
                                        data: data,
                                        filename: store.workspaceExportFilename(),
                                        utType: .json
                                    )
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSidebarIcon)
                                Button("Backup to iCloud") {
                                    if let url = store.writeWorkspaceBackup() {
                                        sessionNotice = "Saved \(url.lastPathComponent)"
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } else {
                                        sessionNotice = "Could not write backup"
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSidebarIcon)
                                Button("Restore backup…") {
                                    guard let data = SessionFilePanel.openJSON() else { return }
                                    sessionNotice = store.importWorkspaceJSON(data)
                                        ? "Restored workspace backup"
                                        : "Not a GrizzyBot workspace backup"
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSidebarIcon)
                            }
                            .padding(.top, 10)

                            let snapshots = store.listWorkspaceSnapshots()
                            if snapshots.isEmpty {
                                Text("No snapshots yet.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textMuted)
                                    .padding(.top, 10)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(snapshots) { snap in
                                        HStack(alignment: .top, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(snap.name)
                                                    .font(.system(size: 13.5, weight: .medium))
                                                    .foregroundStyle(Theme.textBright)
                                                Text("\(snap.botCount) bots · \(snap.messageCount) messages")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(Theme.textSecondary)
                                            }
                                            Spacer()
                                            Button("Restore") {
                                                if store.restoreWorkspaceSnapshot(snap.id) {
                                                    sessionNotice = "Restored “\(snap.name)”"
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.textSidebarIcon)
                                            Button("Delete") {
                                                store.deleteWorkspaceSnapshot(snap.id)
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.orange)
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            }

                            Button("Delete workspace…") {
                                confirmWipeWorkspace = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.orange)
                            .padding(.top, 14)
                        }

                    case .connections:
                        settingsCard(
                            title: "Keys",
                            subtitle: "Composio Connect turns Plugins into real browser OAuth (Slack, GitHub, Box, …). Google apps can use Composio or your own Client ID/Secret below. Keys stay on this Mac. Clear removes a stored key."
                        ) {
                            secretRow(
                                title: "Composio Connect",
                                configured: !(store.appConfig.composioConnectKey ?? "").isEmpty,
                                text: $composioConnect,
                                onClear: { store.clearSecret(.composioConnect) }
                            )
                            secretRow(
                                title: "Composio API",
                                configured: store.appConfig.composioApiKey != nil,
                                text: $composioApi,
                                onClear: { store.clearSecret(.composioApi) }
                            )
                                .padding(.top, 12)
                            secretRow(
                                title: "Box.com",
                                configured: store.appConfig.boxConfigured,
                                text: $boxToken,
                                onClear: { store.clearSecret(.box) }
                            )
                                .padding(.top, 12)
                            secretRow(
                                title: "Brave Search (optional)",
                                configured: store.appConfig.braveSearchConfigured,
                                text: $braveSearchKey,
                                onClear: { store.clearSecret(.braveSearch) }
                            )
                                .padding(.top, 12)
                            Text("Box.com is an optional developer token for the Box plugin when you are not using Composio Connect. Brave Search is used for web_search when set; otherwise DuckDuckGo and Wikipedia.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 8)
                            GrizzyButton(title: "Save keys", variant: .cream, size: .sm) {
                                persistKeys()
                            }
                            .padding(.top, 14)
                        }

                        settingsCard(
                            title: "Google (bypass Composio)",
                            subtitle: "Your Google Cloud OAuth Client ID/Secret for Gmail, Calendar, Sheets, Docs, and Drive. Keep using the same credentials if sign-in already worked once."
                        ) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Authorized redirect URI")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(GoogleOAuth.loopbackRedirectURI)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Theme.textBright)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        GoogleOAuth.loopbackRedirectURI,
                                        forType: .string
                                    )
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.textGhost)
                            }
                            .padding(.bottom, 4)

                            Text("Paste that exact URI (no trailing slash) into Google Cloud → your OAuth client → Authorized redirect URIs, then Save.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            DisclosureGroup(isExpanded: $googleSetupExpanded) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(Array(GoogleOAuth.setupGuide.enumerated()), id: \.element.id) { index, step in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(index + 1). \(step.title)")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(Theme.textBright)
                                            Text(step.body)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(Theme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let link = step.linkURL {
                                                Button(step.linkTitle ?? link.host ?? "Open") {
                                                    NSWorkspace.shared.open(link)
                                                }
                                                .buttonStyle(.plain)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(Theme.textGhost)
                                                .padding(.top, 2)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text(googleSetupExpanded ? "Hide setup guide" : "Show step-by-step setup guide")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textBright)
                            }

                            secretRow(
                                title: "Google Client ID",
                                configured: !(store.appConfig.googleClientId ?? "").isEmpty,
                                text: $googleClientId,
                                onClear: { store.clearSecret(.googleClientId) }
                            )
                            .padding(.top, 12)
                            secretRow(
                                title: "Google Client Secret",
                                configured: !(store.appConfig.googleClientSecret ?? "").isEmpty,
                                text: $googleClientSecret,
                                onClear: { store.clearSecret(.googleClientSecret) }
                            )
                            .padding(.top, 12)

                            Text(
                                store.appConfig.googleOAuthConfigured
                                    ? "Configured. Open Plugins and Connect Gmail, or use Sign in with Google for all Google apps at once."
                                    : "After saving both fields, open Plugins → Connect on Gmail (or Sign in with Google)."
                            )
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 8)

                            HStack(spacing: 10) {
                                GrizzyButton(title: "Save Google credentials", variant: .cream, size: .sm) {
                                    persistGoogleKeys()
                                }
                                if store.appConfig.googleOAuthConfigured {
                                    GrizzyButton(title: "Open Plugins", variant: .outline, size: .sm) {
                                        store.closeAppSettings()
                                        store.openPlugins()
                                    }
                                }
                            }
                            .padding(.top, 14)
                        }

                        settingsCard(
                            title: "Subscription sign-in",
                            subtitle: "ChatGPT Plus/Pro, Copilot, and SuperGrok. Opens the model Connect sheet — no API key required."
                        ) {
                            GrizzyButton(title: "Open model sign-in", variant: .cream, size: .sm) {
                                store.closeAppSettings()
                                store.openModelSettings()
                            }
                        }

                    case .computer:
                        settingsCard(
                            title: "Default computer",
                            subtitle: "Used when a bot’s computer mode is Auto."
                        ) {
                            GrizzySelect(options: ComputerMode.selectableCases, selection: $computerMode)
                            Text("Auto follows your host choice (in-app browser or This Mac). In-app browser keeps cookies per bot.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 10)
                        }
                        .onChange(of: computerMode) { _, mode in
                            var config = store.appConfig
                            config.defaultComputerMode = mode
                            store.saveAppConfig(config)
                        }

                        settingsCard(
                            title: "This Mac permissions",
                            subtitle: "Accessibility and Screen Recording are required to click and see the desktop. Grant them before a bot uses This Mac."
                        ) {
                            let status = MacAccessibility.permissionStatus()
                            Text(status.accessibility ? "Accessibility is on" : "Accessibility is off")
                                .font(.system(size: 13.5))
                                .foregroundStyle(status.accessibility ? Theme.green : Theme.orange)
                            Text(status.screenRecording ? "Screen Recording is on" : "Screen Recording is off")
                                .font(.system(size: 13.5))
                                .foregroundStyle(status.screenRecording ? Theme.green : Theme.orange)
                                .padding(.top, 6)
                            HStack(spacing: 10) {
                                GrizzyButton(title: "Open Accessibility", variant: .cream, size: .sm) {
                                    MacAccessibility.promptAccessibility()
                                }
                                GrizzyButton(title: "Open Screen Recording", variant: .cream, size: .sm) {
                                    MacAccessibility.promptScreenRecording()
                                }
                            }
                            .padding(.top, 12)
                        }

                    case .voice:
                        settingsCard(
                            title: "Text to speech",
                            subtitle: "With an ElevenLabs key, Speak replies uses ElevenLabs. Without a key, GrizzyBot uses on-device macOS voices. Voice can be a name (Rachel, Adam) or an ElevenLabs voice id."
                        ) {
                            secretRow(
                                title: "ElevenLabs API key",
                                configured: store.appConfig.ttsConfigured,
                                text: $ttsKey,
                                onClear: { store.clearSecret(.tts) }
                            )
                            GrizzyField(label: "Voice", placeholder: "Rachel", text: $ttsVoice)
                                .padding(.top, 12)
                            GrizzyButton(title: "Save voice", variant: .cream, size: .sm) {
                                persistVoice()
                            }
                            .padding(.top, 14)
                        }

                    case .tools:
                        settingsCard(
                            title: "MCP servers",
                            subtitle: "Green means the server answered tools/list. Red means it did not. Expand a server to turn individual tools on or off for new bots."
                        ) {
                            McpServersToolsBlock(
                                scope: .appDefaults,
                                showsEditor: true,
                                editingId: editingMcpId,
                                onEdit: { beginEdit($0) },
                                onDelete: { server in
                                    if editingMcpId == server.id { clearMcpForm() }
                                    store.deleteMcpServer(server.id)
                                }
                            )

                            Divider()
                                .overlay(Theme.borderListRowsAlt)
                                .padding(.vertical, 8)

                            Button {
                                if editingMcpId != nil {
                                    clearMcpForm()
                                } else {
                                    addMcpOpen.toggle()
                                }
                            } label: {
                                HStack {
                                    Text(editingMcpId == nil ? "Add MCP server" : "Editing \(mcpName.isEmpty ? "server" : mcpName)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.textBright)
                                    Spacer()
                                    Text(addMcpOpen || editingMcpId != nil ? "▾" : "▸")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textMuted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if addMcpOpen || editingMcpId != nil {
                                mcpEditorForm
                                    .padding(.top, 10)
                            }
                        }

                        settingsCard(
                            title: "Default tools for new bots",
                            subtitle: "Applied when you create a bot. Existing bots keep their own Tools list. MCP servers are configured above."
                        ) {
                            HStack(spacing: 12) {
                                Button("Enable all") {
                                    store.setAllDefaultTools(enabled: true)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSidebarIcon)

                                Button("Disable all") {
                                    store.setAllDefaultTools(enabled: false)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.orange)
                            }
                            .padding(.bottom, 4)

                            GroupedBuiltinToolsList(scope: .appDefaults)
                        }

                    case .themes:
                        ThemesSettingsView()

                    case .privacy:
                        settingsCard(
                            title: "Privacy on send",
                            subtitle: "Regex PII filter before cloud model calls (GrizzyClaw-style). Critical secrets can fail closed."
                        ) {
                            Toggle("Enable privacy filter", isOn: Binding(
                                get: { store.appConfig.privacyFilter.enabled },
                                set: { value in
                                    var config = store.appConfig
                                    config.privacyFilter.enabled = value
                                    store.saveAppConfig(config)
                                }
                            ))
                            .toggleStyle(.switch)
                            Toggle("Redact before cloud send", isOn: Binding(
                                get: { store.appConfig.privacyFilter.redactBeforeCloudSend },
                                set: { value in
                                    var config = store.appConfig
                                    config.privacyFilter.redactBeforeCloudSend = value
                                    store.saveAppConfig(config)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                            Toggle("Fail closed on critical PII", isOn: Binding(
                                get: { store.appConfig.privacyFilter.failClosed },
                                set: { value in
                                    var config = store.appConfig
                                    config.privacyFilter.failClosed = value
                                    store.saveAppConfig(config)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                        }

                        settingsCard(
                            title: "Lean memory",
                            subtitle: "Heuristic mode injects Pin/Facts only when the prompt looks memory-relevant."
                        ) {
                            Picker("Memory inject", selection: Binding(
                                get: { store.appConfig.memoryRelevanceMode },
                                set: { value in
                                    var config = store.appConfig
                                    config.memoryRelevanceMode = value
                                    store.saveAppConfig(config)
                                }
                            )) {
                                Text("Always (legacy)").tag(MemoryRelevanceGateMode.always)
                                Text("Heuristic").tag(MemoryRelevanceGateMode.heuristic)
                                Text("Off").tag(MemoryRelevanceGateMode.off)
                            }
                            .pickerStyle(.menu)
                            if let botId = store.activeBotId {
                                let clusters = store.memoryDedupeClusters(botId: botId)
                                Text(clusters.isEmpty ? "No near-duplicate Facts for the active bot." : "\(clusters.count) duplicate cluster(s) found.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 10)
                                if !clusters.isEmpty {
                                    GrizzyButton(title: "Merge duplicates", variant: .cream, size: .sm) {
                                        let removed = store.mergeMemoryDuplicates(botId: botId)
                                        sessionNotice = "Removed \(removed.count) duplicate fact(s)."
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }

                        settingsCard(
                            title: "Local OpenAI / MCP gateway",
                            subtitle: "Expose bots at http://127.0.0.1:PORT/v1/chat/completions and /mcp/tools for Cursor."
                        ) {
                            Toggle("Enable local gateway", isOn: Binding(
                                get: { store.appConfig.localGateway.enabled },
                                set: { value in
                                    var config = store.appConfig
                                    config.localGateway.enabled = value
                                    if let port = Int(gatewayPort) { config.localGateway.port = port }
                                    config.localGateway.apiKey = gatewayKey
                                    store.saveAppConfig(config)
                                }
                            ))
                            .toggleStyle(.switch)
                            GrizzyField(label: "Port", placeholder: "8787", text: $gatewayPort)
                                .padding(.top, 8)
                            GrizzyField(label: "API key (optional Bearer)", placeholder: "local-secret", text: $gatewayKey, secure: true)
                                .padding(.top, 8)
                            GrizzyButton(title: "Save gateway", variant: .cream, size: .sm) {
                                var config = store.appConfig
                                if let port = Int(gatewayPort) { config.localGateway.port = port }
                                config.localGateway.apiKey = gatewayKey
                                store.saveAppConfig(config)
                                sessionNotice = config.localGateway.enabled
                                    ? "Gateway listening on port \(config.localGateway.port)"
                                    : "Gateway disabled"
                            }
                            .padding(.top, 10)
                        }

                    case .watchers:
                        settingsCard(
                            title: "Folder watchers",
                            subtitle: "Each watcher is a card. Select one to edit, run it now, or delete it. FSEvents still fire while this is enabled."
                        ) {
                            FolderWatchersSettingsBlock()
                        }

                        settingsCard(
                            title: "MCP Bonjour",
                            subtitle: "Discover `_mcp._tcp` services on the local network (e.g. MacUse)."
                        ) {
                            GrizzyButton(title: "Browse LAN", variant: .cream, size: .sm) {
                                Task {
                                    bonjourHits = await store.discoverMcpBonjour()
                                }
                            }
                            if bonjourHits.isEmpty {
                                Text("No results yet.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 8)
                            } else {
                                ForEach(bonjourHits) { hit in
                                    Text("\(hit.name) — \(hit.httpBaseURL)")
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                        .padding(.top, 6)
                                }
                            }
                        }

                    case .diagnostics:
                        settingsCard(
                            title: "Crash reporting",
                            subtitle: "Sentry receives crashes when a DSN is saved. last-crash.txt is always written locally under Diagnostics."
                        ) {
                            secretRow(
                                title: "Sentry DSN",
                                configured: store.appConfig.sentryConfigured,
                                text: $sentryDSN,
                                onClear: {
                                    store.clearSecret(.sentry)
                                    CrashReporting.install(dsn: nil)
                                }
                            )
                            GrizzyButton(title: "Save Sentry DSN", variant: .cream, size: .sm) {
                                store.applySecret(.sentry, input: sentryDSN)
                                CrashReporting.startSentry(dsn: store.appConfig.sentryDSN)
                                sentryDSN = ""
                                sessionNotice = store.appConfig.sentryConfigured
                                    ? "Sentry is on"
                                    : "Sentry DSN cleared — local crash file only"
                            }
                            .padding(.top, 12)
                        }

                        settingsCard(
                            title: "Last run log",
                            subtitle: "Tool calls, MCP stderr, and agent errors from this session. Copy this when a run fails."
                        ) {
                            Text(store.lastRunLogText())
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 12) {
                                GrizzyButton(title: "Copy last run log", variant: .cream, size: .sm) {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(store.lastRunLogText(), forType: .string)
                                    sessionNotice = "Copied run log"
                                }
                                Button("Copy last crash") {
                                    if let text = CrashReporting.latestCrashText() {
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.clearContents()
                                        pasteboard.setString(DiagnosticScrubber.redact(text), forType: .string)
                                        sessionNotice = "Copied crash log"
                                    } else {
                                        sessionNotice = "No crash log yet"
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSidebarIcon)
                            }
                            .padding(.top, 10)
                            Button("Open diagnostics folder") {
                                NSWorkspace.shared.open(store.diagnosticsDirectory())
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSidebarIcon)
                            .padding(.top, 8)
                        }

                    case .governance:
                        GovernanceSettingsView()

                    case .knowledge:
                        KnowledgeSettingsView()

                    case .components:
                        ComponentsSettingsView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .grizzyScroll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mcpEditorForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            GrizzyField(label: "Name", placeholder: "filesystem", text: $mcpName)
            VStack(alignment: .leading, spacing: 6) {
                Text("Transport")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                GrizzySelect(options: McpTransport.allCases, selection: $mcpTransport)
            }
            .padding(.top, 8)

            if mcpTransport == .stdio {
                GrizzyField(
                    label: "Command",
                    placeholder: "npx",
                    text: $mcpCommand
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Args (space-separated)",
                    placeholder: "-y @modelcontextprotocol/server-filesystem /tmp",
                    text: $mcpArgs
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Env (KEY=value per line)",
                    placeholder: "API_KEY=…",
                    text: $mcpEnv,
                    axis: .vertical,
                    lineLimit: 2...4
                )
                .padding(.top, 8)
            } else {
                GrizzyField(
                    label: "URL",
                    placeholder: mcpTransport == .sse
                        ? "https://example.com/sse"
                        : "https://example.com/mcp",
                    text: $mcpUrl
                )
                .padding(.top, 8)
                GrizzyField(
                    label: "Headers (Name: value per line)",
                    placeholder: "Authorization: Bearer …",
                    text: $mcpHeaders,
                    axis: .vertical,
                    lineLimit: 2...4
                )
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                GrizzyButton(
                    title: editingMcpId == nil ? "Add MCP server" : "Save changes",
                    variant: .cream,
                    size: .sm,
                    disabled: !canAddMcp
                ) {
                    saveMcpServer()
                }

                if editingMcpId != nil {
                    Button("Cancel") {
                        clearMcpForm()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 12)
        }
    }

    private var canAddMcp: Bool {
        let nameOk = !mcpName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mcpTransport {
        case .stdio:
            return nameOk && !mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http, .sse:
            return nameOk && !mcpUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var tokenCountersBody: some View {
        let botId = store.activeBotId
        let bot = store.bots.first(where: { $0.id == botId })
        let stats = store.chatTokenStats(botId: botId ?? "")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text(bot?.name ?? "No bot selected")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                tokenCounterStat(label: "Prompt", value: stats.lastPromptTokens)
                tokenCounterStat(label: "Sent", value: stats.sentTokens)
                tokenCounterStat(label: "Recv", value: stats.receivedTokens)
            }
            HStack(spacing: 12) {
                GrizzyButton(
                    title: "Reset this bot",
                    variant: .cream,
                    size: .sm,
                    disabled: botId == nil
                ) {
                    if let botId {
                        store.resetChatTokens(botId: botId)
                    }
                }
                GrizzyButton(
                    title: "Reset all bots",
                    variant: .outline,
                    size: .sm
                ) {
                    confirmResetAllTokens = true
                }
            }
        }
    }

    private func tokenCounterStat(label: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Text(TokenAccounting.grouped(value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func settingsCard<Content: View>(
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

    private func secretRow(
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

    private func sectionIcon(_ section: AppStore.AppSettingsSection) -> String {
        switch section {
        case .general: return "☺"
        case .connections: return "⌘"
        case .computer: return "▣"
        case .voice: return "♪"
        case .tools: return "⚒"
        case .themes: return "◑"
        case .privacy: return "⚑"
        case .watchers: return "◷"
        case .diagnostics: return "☰"
        case .governance: return "⚖"
        case .knowledge: return "▤"
        case .components: return "▣"
        }
    }

    private func beginEdit(_ server: McpServer) {
        editingMcpId = server.id
        addMcpOpen = true
        mcpName = server.name
        mcpTransport = server.transport
        mcpCommand = server.command
        mcpArgs = McpConfigText.argsLine(server.args)
        mcpEnv = McpConfigText.envLines(server.env)
        mcpUrl = server.url
        mcpHeaders = McpConfigText.headerLines(server.headers)
    }

    private func clearMcpForm() {
        editingMcpId = nil
        addMcpOpen = false
        mcpName = ""
        mcpCommand = ""
        mcpArgs = ""
        mcpEnv = ""
        mcpUrl = ""
        mcpHeaders = ""
        mcpTransport = .stdio
    }

    private func saveMcpServer() {
        let args = McpConfigText.parseArgs(mcpArgs)
        let env = McpConfigText.parseEnv(mcpEnv)
        let headers = McpConfigText.parseHeaders(mcpHeaders)
        if let id = editingMcpId, var existing = store.mcpServers.first(where: { $0.id == id }) {
            let trimmed = mcpName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            existing.name = trimmed
            existing.transport = mcpTransport
            existing.command = mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.args = args
            existing.env = env
            existing.url = mcpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.headers = headers
            store.updateMcpServer(existing)
            store.probeMcpServer(existing.id)
            clearMcpForm()
            return
        }
        guard let added = store.addMcpServer(
            name: mcpName,
            transport: mcpTransport,
            command: mcpCommand,
            args: args,
            env: env,
            url: mcpUrl,
            headers: headers
        ) else { return }
        store.probeMcpServer(added.id)
        clearMcpForm()
    }

    private func load() {
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

    private func persistProfile() {
        var config = store.appConfig
        config.profileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.profileEmail = profileEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveAppConfig(config)
    }

    private func persistKeys() {
        store.applySecret(.composioConnect, input: composioConnect)
        store.applySecret(.composioApi, input: composioApi)
        store.applySecret(.box, input: boxToken)
        store.applySecret(.braveSearch, input: braveSearchKey)
        composioConnect = ""
        composioApi = ""
        boxToken = ""
        braveSearchKey = ""
    }

    private func persistGoogleKeys() {
        store.applySecret(.googleClientId, input: googleClientId)
        store.applySecret(.googleClientSecret, input: googleClientSecret)
        googleClientId = ""
        googleClientSecret = ""
        if !store.appConfig.googleOAuthConfigured {
            googleSetupExpanded = true
        }
    }

    private func persistVoice() {
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

private struct FolderWatchersSettingsBlock: View {
    @Environment(AppStore.self) private var store
    @State private var selectedId: String?
    @State private var name = ""
    @State private var path = ""
    @State private var instructions = ""
    @State private var botId = ""
    @State private var recursive = true
    @State private var enabled = true
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable folder watchers", isOn: Binding(
                get: { store.appConfig.enableFolderWatchers },
                set: { value in
                    var config = store.appConfig
                    config.enableFolderWatchers = value
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)

            if store.folderWatchers.isEmpty {
                Text("No watchers yet. Choose a folder below and click Add watcher — a card will appear here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.folderWatchers) { watcher in
                        watcherCard(watcher)
                    }
                }
            }

            Divider()
                .overlay(Theme.borderListRowsAlt)

            Text(selectedId == nil ? "New watcher" : "Edit watcher")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textBright)

            GrizzyField(label: "Name", placeholder: "Inbox watcher", text: $name)
            HStack(alignment: .bottom, spacing: 8) {
                GrizzyField(label: "Watch folder", placeholder: "~/Documents/Inbox", text: $path)
                Button("Browse…") { pickFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textGhost)
                    .padding(.bottom, 8)
            }
            GrizzyField(
                label: "Instructions",
                placeholder: "Summarize new files…",
                text: $instructions,
                axis: .vertical,
                lineLimit: 2...4
            )
            if !store.bots.isEmpty {
                Picker("Bot", selection: $botId) {
                    Text("Active bot").tag("")
                    ForEach(store.bots) { bot in
                        Text(bot.name).tag(bot.id)
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("Watch subfolders", isOn: $recursive)
                .toggleStyle(.switch)
            Toggle("Enabled", isOn: $enabled)
                .toggleStyle(.switch)

            if let notice {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(notice.hasPrefix("Triggered") || notice.hasPrefix("Saved")
                        ? Theme.green
                        : Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                GrizzyButton(
                    title: selectedId == nil ? "Add watcher" : "Save changes",
                    variant: .cream,
                    size: .sm
                ) {
                    saveFromForm()
                }
                if selectedId != nil {
                    GrizzyButton(title: "Run now", variant: .outline, size: .sm) {
                        if let selectedId { run(id: selectedId) }
                    }
                    Button("New") { resetForm() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textGhost)
                }
            }
        }
        .onAppear {
            store.reloadFolderWatchers()
            if botId.isEmpty {
                botId = store.activeBotId ?? store.bots.first?.id ?? ""
            }
        }
    }

    private func watcherCard(_ watcher: FolderWatcherRecord) -> some View {
        let selected = selectedId == watcher.id
        let botName = store.bots.first(where: { $0.id == watcher.botId })?.name
        let folderExists = FileManager.default.fileExists(
            atPath: (watcher.watchPath as NSString).expandingTildeInPath
        )
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                select(watcher)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(watcher.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        if selected {
                            Text("editing")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textGhost)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(watcher.watchPath.isEmpty ? "No folder chosen" : watcher.watchPath)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(botName ?? "Active bot")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                        if let last = watcher.lastTriggeredAt {
                            Text("Last run \(last)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                        if !folderExists {
                            Text("Folder missing")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.orange)
                        }
                    }
                    if let error = watcher.lastError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Toggle("On", isOn: Binding(
                    get: { watcher.enabled },
                    set: { value in
                        var updated = watcher
                        updated.enabled = value
                        persist(updated)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(watcher.name) enabled")
                Spacer()
                Button("Edit") { select(watcher) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textGhost)
                Button("Run now") { run(id: watcher.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textGhost)
                Button("Delete", role: .destructive) { delete(watcher) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }
        }
        .padding(12)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Theme.orange.opacity(0.55) : Theme.borderListRowsAlt, lineWidth: selected ? 1.5 : 1)
        }
    }

    private func select(_ watcher: FolderWatcherRecord) {
        selectedId = watcher.id
        name = watcher.name
        path = watcher.watchPath
        instructions = watcher.instructions
        botId = watcher.botId ?? ""
        recursive = watcher.recursive
        enabled = watcher.enabled
        notice = nil
    }

    private func resetForm() {
        selectedId = nil
        name = ""
        path = ""
        instructions = ""
        botId = store.activeBotId ?? store.bots.first?.id ?? ""
        recursive = true
        enabled = true
        notice = nil
    }

    private func saveFromForm() {
        var record = store.folderWatchers.first(where: { $0.id == selectedId }) ?? FolderWatcherRecord.makeNew()
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.name.isEmpty { record.name = "Untitled watcher" }
        record.watchPath = path
        record.instructions = instructions
        record.botId = botId.isEmpty ? store.activeBotId : botId
        record.recursive = recursive
        record.enabled = enabled
        persist(record)
        selectedId = record.id
    }

    private func persist(_ record: FolderWatcherRecord) {
        do {
            try store.saveFolderWatcher(record)
            notice = "Saved \(record.name)."
        } catch {
            notice = error.localizedDescription
        }
    }

    private func run(id: String) {
        let result = store.runFolderWatcherNow(id: id)
        notice = result
        if result.hasPrefix("Triggered") {
            store.closeAppSettings()
        }
    }

    private func delete(_ watcher: FolderWatcherRecord) {
        do {
            try store.deleteFolderWatcher(id: watcher.id)
            if selectedId == watcher.id { resetForm() }
            notice = "Deleted \(watcher.name)."
        } catch {
            notice = error.localizedDescription
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Folder GrizzyBot should watch"
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

