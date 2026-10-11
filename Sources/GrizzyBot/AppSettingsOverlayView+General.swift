import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension AppSettingsOverlayView {
    @ViewBuilder
    var generalSection: some View {
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
            title: "Delegation",
            subtitle: "Who answers when a message could go to more than one bot."
        ) {
            Text("Router model")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            GrizzySelect(
                options: BotModelChoice.choices(
                    workspaceProvider: store.modelProvider,
                    workspaceModel: store.modelId,
                    fetched: store.fetchedModels(for: store.modelProvider ?? ModelCatalog.defaultProvider),
                    includeFullCatalog: true,
                    enabledProviders: store.enabledModelSources()
                ),
                selection: Binding(
                    get: {
                        guard let choice = store.appConfig.routerModel else { return .workspaceDefault }
                        return .catalog(provider: choice.provider, modelId: choice.modelId, label: choice.modelId)
                    },
                    set: { store.setRouterModel($0) }
                )
            )
            .padding(.top, 6)
            Text("Optional. Clear matches are routed by simple rules, instantly and for free. When the rules can't tell, this model picks the bot (it sees the message and each bot's role and tools, nothing else). Leave it on “Workspace default” to use rules only.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 6)
        }

        settingsCard(
            title: "Chat",
            subtitle: "How conversations look."
        ) {
            Toggle("Your messages take the bot's colour (one-on-one chats)", isOn: Binding(
                get: { store.appConfig.botColoredChats },
                set: { value in
                    var config = store.appConfig
                    config.botColoredChats = value
                    store.saveAppConfig(config)
                }
            ))
            .toggleStyle(.switch)
        }

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
            title: "Messages while a bot is working",
            subtitle: store.appConfig.queueMode.summary
        ) {
            Picker("When I send mid-run", selection: Binding(
                get: { store.appConfig.queueMode },
                set: { value in
                    var config = store.appConfig
                    config.queueMode = value
                    store.saveAppConfig(config)
                }
            )) {
                ForEach(QueueMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }

        settingsCard(
            title: "Token counters",
            subtitle: "Prompt, Sent, and Recv on the composer come from this bot’s billed usage. Reset them to start a session from zero. Chat messages are not deleted."
        ) {
            tokenCountersBody
        }

        settingsCard(
            title: "Teams",
            subtitle: "Export your bots as one shareable file, or import someone else's."
        ) {
            TeamsSettingsBody()
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
    }

    @ViewBuilder
    var computerSection: some View {
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
    }

    @ViewBuilder
    var voiceSection: some View {
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
    }

    @ViewBuilder
    var themesSection: some View {
        ThemesSettingsView()
    }
}
