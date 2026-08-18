import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

/// OpenMausBot-style app settings modal: General / Connections / Local VM / Voice.
struct AppSettingsOverlayView: View {
    @Environment(AppStore.self) private var store
    @State private var profileName = ""
    @State private var profileEmail = ""
    @State private var composioConnect = ""
    @State private var composioApi = ""
    @State private var boxToken = ""
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
    @State private var snapshotName = ""
    @State private var confirmWipeWorkspace = false
    @State private var sessionNotice: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { store.closeAppSettings() }

            HStack(spacing: 0) {
                nav
                content
            }
            .frame(width: 860, height: 560)
            .background(Theme.bgRightPanel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
            .accessibilityIdentifier(OverlayA11y.settings)
            .accessibilityElement(children: .contain)
        }
        .accessibilityIdentifier(OverlayA11y.settings)
        .onAppear(perform: load)
        .alert("Delete this workspace?", isPresented: $confirmWipeWorkspace) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                store.deleteWorkspace()
                store.closeAppSettings()
            }
        } message: {
            Text("Removes every bot, chat, routine, and file. Your account stays. Snapshots are kept until you delete them.")
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
                            subtitle: "Routines keep firing while GrizzyBot is open. Launch at login needs approval in System Settings → Login Items (release builds)."
                        ) {
                            Toggle("Show menu bar extra", isOn: Binding(
                                get: { store.appConfig.showMenuBar },
                                set: { value in
                                    var config = store.appConfig
                                    config.showMenuBar = value
                                    store.saveAppConfig(config)
                                }
                            ))
                            .toggleStyle(.switch)
                            Toggle("Launch at login", isOn: Binding(
                                get: { store.appConfig.launchAtLogin },
                                set: { value in
                                    var config = store.appConfig
                                    config.launchAtLogin = value
                                    store.saveAppConfig(config)
                                    LoginItemController.setEnabled(value)
                                }
                            ))
                            .toggleStyle(.switch)
                            .padding(.top, 8)
                        }

                        settingsCard(
                            title: "Updates",
                            subtitle: "Sparkle checks GitHub for a signed GrizzyBot DMG. Check for Updates works in Debug; an empty feed means you are already on the latest published build."
                        ) {
                            UpdatesSettingsView()
                        }

                        settingsCard(
                            title: "Shared memory",
                            subtitle: "Every bot reads this. Agents can also remember with scope=shared."
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
                            subtitle: "Composio Connect turns Plugins into real browser OAuth (Gmail, Slack, GitHub, Box, …). Without Connect, paste an API token per app. Keys stay on this Mac. Clear removes a stored key."
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
                            Text("Box.com is an optional developer token for the Box plugin when you are not using Composio Connect. It is not the Composio Connect key.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 8)
                            GrizzyButton(title: "Save keys", variant: .cream, size: .sm) {
                                persistKeys()
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
                            GrizzySelect(options: ComputerMode.allCases, selection: $computerMode)
                            Text("This Mac drives the real desktop (Accessibility + Screen Recording). The in-app browser keeps cookies per bot. Cloud desktop is a stub.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 10)
                        }
                        .onChange(of: computerMode) { _, mode in
                            var config = store.appConfig
                            config.defaultComputerMode = mode
                            store.saveAppConfig(config)
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
                            title: editingMcpId == nil ? "Add an MCP server" : "Edit MCP server",
                            subtitle: "Cursor-style MCP config. Stdio runs a local command; Streamable HTTP posts to an MCP endpoint; HTTP+SSE is the legacy remote transport. Bots call these for real when the tool is enabled."
                        ) {
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

                        if !store.mcpServers.isEmpty {
                            settingsCard(
                                title: "MCP servers",
                                subtitle: "Edit loads the server into the form above. Delete removes it from every bot’s tool list."
                            ) {
                                ForEach(store.mcpServers) { server in
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(server.name)
                                                    .font(.system(size: 14.5, weight: .medium))
                                                    .foregroundStyle(Theme.textBright)
                                                Text(server.transport.rawValue)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Theme.orange)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Theme.orange.opacity(0.12))
                                                    .clipShape(Capsule())
                                                if editingMcpId == server.id {
                                                    Text("editing")
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(Theme.textGhost)
                                                }
                                            }
                                            Text(server.summaryLine)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button("Edit") {
                                            beginEdit(server)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.textGhost)
                                        Button("Delete") {
                                            if editingMcpId == server.id { clearMcpForm() }
                                            store.deleteMcpServer(server.id)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.orange)
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }

                        settingsCard(
                            title: "Default tools for new bots",
                            subtitle: "Applied when you create a bot. Existing bots keep their own Tools settings. MCP servers appear here after you add them."
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
                            .padding(.bottom, 8)

                            ForEach(store.knownToolDefinitions) { tool in
                                defaultToolRow(tool)
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
                                        pasteboard.setString(text, forType: .string)
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
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .grizzyScroll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .diagnostics: return "☰"
        }
    }

    private func defaultToolRow(_ tool: AgentToolDefinition) -> some View {
        let enabled = store.appConfig.defaultEnabledTools.contains(tool.id)
        return Button {
            store.setDefaultTool(tool.id, enabled: !enabled)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tool.label)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        if tool.kind != .builtin {
                            Text(tool.kind == .mcp ? "mcp" : "custom")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    Text(tool.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Capsule()
                    .fill(enabled ? Theme.orange : Theme.bgChip)
                    .frame(width: 40, height: 24)
                    .overlay(alignment: enabled ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.textCream)
                            .frame(width: 18, height: 18)
                            .padding(3)
                    }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func beginEdit(_ server: McpServer) {
        editingMcpId = server.id
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
            clearMcpForm()
            return
        }
        guard store.addMcpServer(
            name: mcpName,
            transport: mcpTransport,
            command: mcpCommand,
            args: args,
            env: env,
            url: mcpUrl,
            headers: headers
        ) != nil else { return }
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
        boxToken = ""
        ttsKey = ""
        sentryDSN = ""
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
        composioConnect = ""
        composioApi = ""
        boxToken = ""
    }

    private func persistVoice() {
        store.applySecret(.tts, input: ttsKey)
        var config = store.appConfig
        config.ttsVoice = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveAppConfig(config)
        ttsKey = ""
    }
}
