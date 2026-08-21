import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

struct RightPanelView: View {
    @Environment(AppStore.self) private var store

    @State private var createName = ""
    @State private var createTitle = ""
    @State private var createDescription = ""

    @State private var settingsName = ""
    @State private var settingsTitle = ""
    @State private var settingsDescription = ""
    @State private var settingsInstructions = ""
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var settingsError: String?
    @State private var settingsLoadedFor: String?
    @State private var redactedExport = true

    var body: some View {
        Group {
            if let panel = store.panel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch panel {
                        case .computer:
                            computerPanel
                        case .create:
                            createPanel
                        case .settings:
                            settingsPanel
                        case .routine:
                            routinePanel
                        case .canvas:
                            CanvasPanelView()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .grizzyScroll()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bot: Bot? { store.activeBot }
    private var computer: ComputerStatus? {
        guard let id = bot?.id else { return nil }
        return store.computers[id]
    }

    // MARK: - Computer

    private var computerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(
                left: computer?.state.rawValue ?? bot?.status ?? "",
                showGear: true
            )

            ZStack {
                Theme.bgScreen
                if store.computerOpen {
                    screenLabel
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(16)
                } else if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
                    ThisMacScreenPreview(botId: bot.id, pollSeconds: 3, fill: true)
                } else if let bot, let data = AppComputerRuntime.shared.cachedJPEG(for: bot.id),
                          let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    screenLabel
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.openComputerOverlay() }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                Text(statusCaption)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if let bot {
                    if computer?.controlHolder == .user {
                        GrizzyButton(title: "Release", variant: .outline, size: .sm) {
                            store.release(botId: bot.id)
                        }
                    } else {
                        GrizzyButton(title: "Take control", variant: .outline, size: .sm) {
                            store.openComputerOverlay()
                        }
                    }
                }
            }
            .padding(.top, 12)

            if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
                Text("Preview only — the bot clicks your real Mac. Take control to type passwords yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 8)
            }

            Text("Routines")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 30)
                .padding(.bottom, 12)

            if let bot {
                let list = store.routines(for: bot.id)
                ForEach(list) { routine in
                    HStack(spacing: 6) {
                        Button {
                            store.openRoutine(routine)
                        } label: {
                            HStack(spacing: 8) {
                                Text("◷")
                                    .foregroundStyle(Theme.orange)
                                Text(routine.name)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(Theme.textBright)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Cron.formatCron(routine.cron))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.runRoutine(routine.id)
                        } label: {
                            Text("▶")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textCream)
                                .frame(width: 28, height: 28)
                                .background(Theme.bgCream.opacity(0.9))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Run now")
                    }
                    .contextMenu {
                        Button("Edit") { store.openRoutine(routine) }
                        Button("Run now") { store.runRoutine(routine.id) }
                        Button(routine.active ? "Pause" : "Resume") {
                            store.setRoutineActive(routine.id, active: !routine.active)
                        }
                        Button("Delete", role: .destructive) {
                            store.deleteRoutine(routine.id)
                        }
                    }
                }

                Button {
                    store.runNow(botId: bot.id)
                } label: {
                    Text("Run now")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .help("Run the next due routine")

                Button {
                    store.openNewRoutine()
                } label: {
                    Text("+ New routine")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textSidebarIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Text("Files")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 24)
                    .padding(.bottom, 10)

                let entries = store.botHomeEntries(botId: bot.id)
                if entries.isEmpty {
                    Text("Ask the bot to write a note, list files, or search the web.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.isDirectory ? "📁" : "📄")
                                .font(.system(size: 12))
                            Text(entry.path)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textBright)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var screenLabel: some View {
        if store.computerOpen {
            Text("Open in full window")
        } else if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
            Text("This Mac preview — Screen Recording required")
        } else if store.booting || computer?.state == .booting {
            Text("Booting live desktop…")
        } else if computer?.state == .running {
            Text("\(bot?.name ?? "Bot")'s screen")
        } else if computer?.state == .suspended {
            Text("Computer is asleep — take control to wake it")
        } else if computer?.state == .error {
            Text("Computer failed to boot")
        } else {
            Text("Computer is stopped")
        }
    }

    private var statusCaption: String {
        if computer?.controlHolder == .user { return "You have control (real Mac)" }
        if let bot, store.isThisMacComputer(botId: bot.id) || computer?.kind == .desktop {
            return "This Mac · live preview"
        }
        if computer?.state == .suspended { return "Asleep" }
        return "\(bot?.name ?? "Bot")'s screen"
    }

    // MARK: - Create

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New bot")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                closeButton
            }

            GrizzyField(label: "Name", placeholder: "Name this bot", text: $createName)
                .padding(.top, 24)

            Text("Start from")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BotTemplates.all) { template in
                    Button {
                        createName = template.name
                        createTitle = template.title
                        createDescription = template.blurb
                        _ = store.createBot(from: template, name: template.name)
                        createName = ""
                        createTitle = ""
                        createDescription = ""
                        store.openPanel(nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textBright)
                            Text(template.blurb)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            GrizzyField(label: "Title", placeholder: "Describe what this bot does", text: $createTitle)
                .padding(.top, 12)
            GrizzyField(
                label: "Description",
                placeholder: "What this bot is for",
                text: $createDescription,
                axis: .vertical,
                lineLimit: 4...8
            )
            .padding(.top, 12)

            Button {
                let name = createName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _ = store.createBot(
                    name: name,
                    title: createTitle,
                    description: createDescription,
                    instructions: createDescription
                )
                createName = ""
                createTitle = ""
                createDescription = ""
                store.openPanel(nil)
            } label: {
                Text("Create")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .opacity(createName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(createName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 16)
        }
    }

    // MARK: - Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(left: computer?.state.rawValue ?? bot?.status ?? "", showGear: false)
                .onAppear { syncSettings() }
                .onChange(of: bot?.id) { _, _ in syncSettings() }

            if let bot {
                BotAvatarView(color: bot.color, size: 64)
                    .frame(maxWidth: .infinity)

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
                    settingsToggle(
                        title: componentId,
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

                toolsSection(bot)

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        store.updateBot(
                            botId: bot.id,
                            name: settingsName,
                            title: settingsTitle,
                            description: settingsDescription,
                            instructions: settingsInstructions
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

    private func toolsSection(_ bot: Bot) -> some View {
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

            ForEach(store.knownToolDefinitions) { tool in
                settingsToggle(
                    title: tool.label,
                    subtitle: tool.kind == .builtin
                        ? tool.subtitle
                        : "\(tool.kind == .mcp ? "MCP" : "Custom") · \(tool.subtitle)",
                    isOn: bot.isToolEnabled(tool.id)
                ) {
                    store.setBotTool(bot.id, toolId: tool.id, enabled: !bot.isToolEnabled(tool.id))
                }
            }

            Text("Add MCP servers in App Settings → Tools.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 4)
        }
    }

    private func modelChoices(for bot: Bot) -> [BotModelChoice] {
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

    private func syncSettings() {
        guard let bot, settingsLoadedFor != bot.id else { return }
        settingsName = bot.name
        settingsTitle = bot.title
        settingsDescription = bot.description
        settingsInstructions = bot.instructions.isEmpty ? bot.description : bot.instructions
        settingsLoadedFor = bot.id
        confirmDelete = false
        settingsError = nil
    }

    private func settingsToggle(
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

    private func exportBot(_ bot: Bot) {
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

    // MARK: - Routine

    private var routinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    store.openPanel(.computer)
                } label: {
                    Text("‹")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textChevron)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Routine")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)
                Spacer()
                Button {
                    store.openPanel(nil)
                } label: {
                    Text("✕")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            GrizzyField(
                label: "Name",
                labelSize: 14,
                placeholder: "Name",
                text: Binding(
                    get: { store.routineDraft.name },
                    set: { store.routineDraft.name = $0 }
                )
            )
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 8) {
                Text("Instruction")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                TextField(
                    "Instruction",
                    text: Binding(
                        get: { store.routineDraft.prompt },
                        set: { store.routineDraft.prompt = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(6...)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textBright)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.borderInputsDark, lineWidth: 1)
                }
            }
            .padding(.top, 12)

            Text("Assign to bot")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if store.visibleBots.isEmpty {
                Text("Create a bot first.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            } else {
                let options = store.visibleBots
                let selected = options.first(where: { $0.id == store.routineDraft.botId }) ?? options.first!
                GrizzySelect(
                    options: options.map(\.id),
                    selection: Binding(
                        get: {
                            store.routineDraft.botId.isEmpty
                                ? (selected.id)
                                : store.routineDraft.botId
                        },
                        set: { store.routineDraft.botId = $0 }
                    ),
                    label: { id in
                        store.bots.first(where: { $0.id == id })?.name ?? id
                    }
                )
            }

            Text("When to run")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
                .padding(.bottom, 8)

            RoutineScheduleView(
                preset: Binding(
                    get: { store.routineDraft.preset },
                    set: { store.routineDraft.preset = $0 }
                )
            )

            Button {
                store.saveRoutineDraft(botId: bot?.id)
            } label: {
                Text(store.editingRoutineId == nil ? "Create routine" : "Save changes")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textCream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgCream)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .disabled(store.visibleBots.isEmpty)
            .opacity(store.visibleBots.isEmpty ? 0.45 : 1)

            if let editingId = store.editingRoutineId {
                HStack(spacing: 12) {
                    Button {
                        store.runRoutine(editingId)
                    } label: {
                        Text("Run now")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textBright)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Theme.borderInputsDark, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.deleteRoutine(editingId)
                    } label: {
                        Text("Delete")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.orange)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
        }
    }

    // MARK: - Shared

    private func panelHeader(left: String, showGear: Bool) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if showGear {
                Button {
                    store.openPanel(.settings)
                } label: {
                    Text("⚙")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textBright)
                }
                .buttonStyle(.plain)
            }
            closeButton
        }
        .padding(.bottom, 16)
    }

    private var closeButton: some View {
        Button {
            store.openPanel(nil)
        } label: {
            Text("✕")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textBright)
        }
        .buttonStyle(.plain)
    }
}
