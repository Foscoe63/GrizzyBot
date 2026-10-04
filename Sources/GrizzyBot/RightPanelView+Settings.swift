import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension RightPanelView {
    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(left: computer?.state.rawValue ?? bot?.status ?? "", showGear: false)
                .onAppear { syncSettings() }
                .onChange(of: bot?.id) { _, _ in syncSettings() }

            if let bot {
                BotAvatarView(bot: bot, size: 64)
                    .frame(maxWidth: .infinity)
                avatarControls(bot)
                    .padding(.top, 12)

                GrizzyField(label: "Name", placeholder: "Name", text: $settingsName)
                    .padding(.top, 24)
                GrizzyField(label: "Title", placeholder: "Title", text: $settingsTitle)
                    .padding(.top, 12)
                GrizzyField(
                    label: "Description",
                    placeholder: "Description",
                    text: $settingsDescription,
                    axis: .vertical,
                    lineLimit: 4...8
                )
                .padding(.top, 12)
                GrizzyField(
                    label: "Instructions",
                    placeholder: "What this bot should always do",
                    text: $settingsInstructions,
                    axis: .vertical,
                    lineLimit: 4...8
                )
                .padding(.top, 12)
                GrizzyField(
                    label: "Working folder",
                    placeholder: "~/Projects/my-app (optional; relative file tools read and write here)",
                    text: $settingsWorkingFolder
                )
                .padding(.top, 12)
                Text("Relative read/write/list use this folder. Shell, MEMORY.md, and PLAN.md stay in the bot home. MCP does not inherit it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)

                Text("Granted folders")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                if store.grantedFolders.isEmpty {
                    Text("None yet. Add folders in Settings → Folders, then assign them here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 4)
                } else {
                    Text("This bot can read and write these folders without asking each time.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 4)
                    ForEach(store.grantedFolders) { folder in
                        settingsToggle(
                            title: folder.name,
                            subtitle: folder.path,
                            isOn: bot.grantedFolderIds.contains(folder.id)
                        ) {
                            store.setBotFolder(
                                bot.id,
                                folderId: folder.id,
                                granted: !bot.grantedFolderIds.contains(folder.id)
                            )
                        }
                    }
                }
                GrizzyField(
                    label: "Memory",
                    placeholder: "Facts this bot should keep. Standing rules go under ## Pin.",
                    text: Binding(
                        get: { store.botMemory(botId: bot.id) },
                        set: { store.setBotMemory(botId: bot.id, text: $0) }
                    ),
                    axis: .vertical,
                    lineLimit: 6...16
                )
                .padding(.top, 12)
                Text("Saved as MEMORY.md in this bot’s home. Newest facts are what the model sees first; search_memory can recall the rest.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)

                Text("Model")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                GrizzySelect(
                    options: modelChoices(for: bot),
                    selection: Binding(
                        get: { BotModelChoice.current(bot: bot) },
                        set: { store.setBotModel(bot.id, choice: $0) }
                    )
                )
                .padding(.top, 8)
                Text("Workspace default uses the model from Connect. Pick a catalog model to override it for this bot only.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)

                Text("Visibility")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                Picker("Visibility", selection: Binding(
                    get: { bot.visibility },
                    set: { store.patchBot(bot.id, visibility: $0) }
                )) {
                    ForEach(BotVisibility.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)
                Text("Private bots stay off group pickers. Shared bots can join rooms.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)

                Text("Runtime")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                Picker("Runtime", selection: Binding(
                    get: { bot.runtime },
                    set: { store.patchBot(bot.id, runtime: $0) }
                )) {
                    ForEach(BotRuntime.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)
                GrizzyField(
                    label: "AG-UI URL",
                    placeholder: "http://127.0.0.1:4200/",
                    text: Binding(
                        get: { bot.aguiURL ?? "" },
                        set: { store.patchBot(bot.id, aguiURL: $0) }
                    )
                )
                .padding(.top, 8)
                Text("An AG-UI endpoint is a coworker you already run (LangGraph, Mastra, CrewAI). Tools still execute in GrizzyBot through policy and audit after RUN_FINISHED; the next POST carries tool results and state. Bearer token: store it as connection secret agui:<bot-id> if needed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)

                Text("Components")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                Text("Published cards this bot may present. Drafts in Settings → Components stay hidden until you publish.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
                let published = AgentComponentCatalog.allIds + store.sandboxComponents.filter(\.published).map(\.id)
                ForEach(published, id: \.self) { componentId in
                    let label = AgentComponentCatalog.allIds.contains(componentId)
                        ? componentId
                        : (store.sandboxComponents.first(where: { $0.id == componentId })?.title ?? componentId)
                    settingsToggle(
                        title: label,
                        subtitle: AgentComponentCatalog.allIds.contains(componentId)
                            ? "Built-in card"
                            : "Published playground card",
                        isOn: bot.enabledComponents.contains(componentId)
                    ) {
                        store.setBotComponent(
                            bot.id,
                            componentId: componentId,
                            enabled: !bot.enabledComponents.contains(componentId)
                        )
                    }
                }

                Text("Color")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                HStack(spacing: 8) {
                    ForEach(botColors, id: \.self) { hex in
                        Button {
                            store.patchBot(bot.id, color: hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if bot.color == hex {
                                        Circle().stroke(Theme.textBright, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)

                settingsToggle(
                    title: "Chief of Staff",
                    subtitle: "Coordinates the roster. Only one bot can hold this role.",
                    isOn: bot.chiefOfStaff
                ) {
                    store.setChiefOfStaff(bot.id, enabled: !bot.chiefOfStaff)
                }
                .padding(.top, 18)

                settingsToggle(
                    title: "Auto-approve tools",
                    subtitle: "Skip Allow/Deny prompts for shell and file tools.",
                    isOn: bot.autoApprove
                ) {
                    store.patchBot(bot.id, autoApprove: !bot.autoApprove)
                }

                settingsToggle(
                    title: "Shell network access",
                    subtitle: "Let shell commands reach the network (curl, git, pip). Off keeps a prompt-injected command from sending files out.",
                    isOn: bot.shellNetwork
                ) {
                    store.patchBot(bot.id, shellNetwork: !bot.shellNetwork)
                }

                settingsToggle(
                    title: "Speak replies",
                    subtitle: "Use configured TTS voice when a reply finishes.",
                    isOn: bot.speakReplies
                ) {
                    store.patchBot(bot.id, speakReplies: !bot.speakReplies)
                }

                settingsToggle(
                    title: "Notifications",
                    subtitle: "Notify when this bot finishes a run.",
                    isOn: bot.notifications
                ) {
                    store.patchBot(bot.id, notifications: !bot.notifications)
                }

                Text("Computer mode")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 16)
                GrizzySelect(
                    options: ComputerMode.selectableCases,
                    selection: Binding(
                        get: { bot.computerMode },
                        set: { store.patchBot(bot.id, computerMode: $0) }
                    )
                )
                .padding(.top, 8)

                skillsSection(bot)

                toolsSection(bot)

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        store.updateBot(
                            botId: bot.id,
                            name: settingsName,
                            title: settingsTitle,
                            description: settingsDescription,
                            instructions: settingsInstructions,
                            workingFolder: settingsWorkingFolder
                        )
                    } label: {
                        Text("Save")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textCream)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.bgCream)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        exportBot(bot)
                    } label: {
                        Text("Export")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Toggle("Redact chat history (share-safe)", isOn: $redactedExport)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .toggleStyle(.checkbox)
                        .padding(.top, 4)

                    if confirmDelete {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("This permanently deletes \(bot.name), including thread, computer, memory, and routines. Bots it created stay in your list.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.textGhost)
                                .lineSpacing(13.5 * 0.45)
                            HStack(spacing: 12) {
                                Button {
                                    confirmDelete = false
                                } label: {
                                    Text("Cancel")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    deleting = true
                                    store.deleteBot(bot.id)
                                    deleting = false
                                    confirmDelete = false
                                } label: {
                                    Text(deleting ? "Deleting…" : "Delete")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.textBrightAlt)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(Theme.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(deleting)
                            }
                            .padding(.top, 12)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.bgDeleteConfirm)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderDelete, lineWidth: 1)
                        }
                    } else {
                        Button {
                            confirmDelete = true
                        } label: {
                            Text("Delete bot")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    if let settingsError {
                        Text(settingsError)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.orange)
                    }
                }
                .padding(.top, 20)
            }
        }
    }

    func skillsSection(_ bot: Bot) -> some View {
        let skills = store.skills
        let onCount = skills.filter { bot.isSkillEnabled($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    skillsExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Skills")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(onCount)/\(skills.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textGhost)
                        Text(skillsExpanded ? "▾" : "▸")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skills")
                .accessibilityHint(skillsExpanded ? "Collapse" : "Expand")
                Spacer()
                Button("Enable all") {
                    store.setAllBotSkills(bot.id, enabled: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSidebarIcon)
                .disabled(onCount == skills.count)
                .opacity(onCount == skills.count ? 0.4 : 1)

                Button("Disable all") {
                    store.setAllBotSkills(bot.id, enabled: false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.orange)
                .disabled(onCount == 0)
                .opacity(onCount == 0 ? 0.4 : 1)
            }
            .padding(.top, 18)

            if skillsExpanded {
                Text("Packaged workflows this bot may load. Disabled skills stay out of its catalog and its / menu. Add or write skills in the sidebar's Skills panel.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)

                if skills.isEmpty {
                    Text("No skills installed.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(skills) { skill in
                            ToolCapsuleToggle(
                                title: skill.id,
                                subtitle: skill.description,
                                badge: skill.source == .user ? "user" : nil,
                                isOn: bot.isSkillEnabled(skill.id),
                                action: {
                                    store.setBotSkill(
                                        bot.id,
                                        skillId: skill.id,
                                        enabled: !bot.isSkillEnabled(skill.id)
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
        // Skills live on disk; pick up anything added since the app launched.
        .onAppear { store.reloadSkills() }
    }

    func toolsSection(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tools")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Enable all") {
                    store.setAllBotTools(bot.id, enabled: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSidebarIcon)
                .disabled(bot.allToolsEnabled(knownIds: store.knownToolIds))
                .opacity(bot.allToolsEnabled(knownIds: store.knownToolIds) ? 0.4 : 1)

                Button("Disable all") {
                    store.setAllBotTools(bot.id, enabled: false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.orange)
                .disabled(bot.noToolsEnabled)
                .opacity(bot.noToolsEnabled ? 0.4 : 1)
            }
            .padding(.top, 18)

            Text("Choose which tools this bot may use. Disabled tools never appear to the model — the chat header also shows when Shell or Computer are off.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)

            if !store.mcpServers.isEmpty {
                Text("MCP servers")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
                McpServersToolsBlock(scope: .bot(bot.id))
            }

            GroupedBuiltinToolsList(scope: .bot(bot.id))

            Text("Add MCP servers in App Settings → Tools.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 4)
        }
        .onAppear { store.probeAllMcpServers() }
    }

    func modelChoices(for bot: Bot) -> [BotModelChoice] {
        var options = BotModelChoice.choices(
            workspaceProvider: store.modelProvider,
            workspaceModel: store.modelId,
            fetched: store.fetchedModels(for: store.modelProvider ?? ModelCatalog.defaultProvider),
            includeFullCatalog: true,
            enabledProviders: store.enabledModelSources()
        )
        let current = BotModelChoice.current(bot: bot)
        if !options.contains(current) {
            options.insert(current, at: 1)
        }
        return options
    }

    func syncSettings() {
        guard let bot, settingsLoadedFor != bot.id else { return }
        settingsName = bot.name
        settingsTitle = bot.title
        settingsDescription = bot.description
        settingsInstructions = bot.instructions.isEmpty ? bot.description : bot.instructions
        settingsWorkingFolder = bot.workingFolder ?? ""
        settingsLoadedFor = bot.id
        confirmDelete = false
        settingsError = nil
    }

    func settingsToggle(
        title: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Capsule()
                    .fill(isOn ? Theme.orange : Theme.bgChip)
                    .frame(width: 40, height: 24)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.textCream)
                            .frame(width: 18, height: 18)
                            .padding(3)
                    }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    func exportBot(_ bot: Bot) {
        guard let manifest = store.exportManifest(botId: bot.id, redacted: redactedExport) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = store.exportFilename(for: bot.id)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(manifest)
                try data.write(to: url, options: .atomic)
            } catch {
                settingsError = error.localizedDescription
            }
        }
    }
}
