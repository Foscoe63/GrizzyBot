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
            if store.appConfig.routerModel != nil {
                HStack {
                    Stepper(
                        "Give up after \(Int(store.appConfig.routerTimeoutSeconds)) s",
                        value: Binding(
                            get: { store.appConfig.routerTimeoutSeconds },
                            set: {
                                var config = store.appConfig
                                config.routerTimeoutSeconds = RoutingMemory.clampedTimeout($0)
                                store.saveAppConfig(config)
                            }
                        ),
                        in: RoutingMemory.timeoutRange,
                        step: 1
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.top, 8)
                Text("A message waits this long for the router before going to its usual bot. A small hosted or local model should answer in well under a second; if the timings below are slower, pick a smaller model or lower the limit. \(store.routingMemory.summary)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
            }
        }

        settingsCard(
            title: "Chat",
            subtitle: "How conversations look."
        ) {
            configToggle("Bot colour in one-on-one chats", "Your messages take the bot's colour. Off keeps them neutral.", \.botColoredChats)
        }

        settingsCard(
            title: "Background",
            subtitle: "Routines run on a timer while GrizzyBot is open. Background routines wake the app through a LaunchAgent (signed Release builds)."
        ) {
            configToggle("Show menu bar icon", "Keeps GrizzyBot one click away.", \.showMenuBar) { on in
                if !on {
                    updateConfig { $0.menuBarOnly = false }
                    MainWindowController.applyMenuBarOnly(false)
                }
            }
            configToggle("Menu bar only", "Launch to the menu bar; use Open GrizzyBot to show the main window.", \.menuBarOnly) { on in
                if on { updateConfig { $0.showMenuBar = true } }
                MainWindowController.applyMenuBarOnly(on)
            }
            configToggle("Launch at login", LoginItemController.statusMessage, \.launchAtLogin) { on in
                applyBackgroundService(LoginItemController.setEnabled(on), on: on, keyPath: \.launchAtLogin, name: "Launch at login")
            }
            configToggle("Background routines", "Lets due routines wake the app even when it is closed.", \.backgroundRoutines) { on in
                applyBackgroundService(RoutineAgentController.setEnabled(on), on: on, keyPath: \.backgroundRoutines, name: "Background routines")
            }
            #if DEBUG
            Text("Launch at login and background routines require a signed Release build. SMAppService rejects ad-hoc Debug bundles.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
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
            SettingsRow(title: "When I send mid-run") {
                SettingsSegmented(
                    options: QueueMode.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { store.appConfig.queueMode },
                        set: { value in updateConfig { $0.queueMode = value } }
                    )
                )
            }
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
                        sessionNotice = store.lastWorkspaceError ?? "Could not write backup"
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSidebarIcon)
                Button("Restore backup…") {
                    guard let data = SessionFilePanel.openJSON() else { return }
                    sessionNotice = store.importWorkspaceJSON(data)
                        ? "Restored workspace backup"
                        : (store.lastWorkspaceError ?? "Not a GrizzyBot workspace backup")
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
                onClear: { store.clearSecret(.tts) },
                onCommit: { persistVoice() }
            )
            GrizzyField(label: "Voice", placeholder: "Rachel", text: $ttsVoice, onCommit: { persistVoice() })
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

extension AppSettingsOverlayView {
    /// A background service can refuse to register (unsigned build, missing plist, approval pending).
    /// Never leave the switch on for something that is not actually running.
    func applyBackgroundService(
        _ result: LoginItemResult,
        on: Bool,
        keyPath: WritableKeyPath<AppConfig, Bool>,
        name: String
    ) {
        switch result {
        case .enabled, .disabled:
            break
        case .unavailableInDebug:
            sessionNotice = "\(name) needs a signed Release build. Your choice is saved and applies there."
        case .failed(let reason):
            updateConfig { $0[keyPath: keyPath] = !on }
            sessionNotice = "\(name) could not be \(on ? "turned on" : "turned off"): \(reason)"
        }
    }
}
