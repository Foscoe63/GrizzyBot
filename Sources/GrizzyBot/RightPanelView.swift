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
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var settingsError: String?
    @State private var settingsLoadedFor: String?

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
                screenLabel
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(16)
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
                            store.takeControl(botId: bot.id)
                        }
                    }
                }
            }
            .padding(.top, 12)

            Text("Routines")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 30)
                .padding(.bottom, 12)

            if let bot {
                let list = store.routines(for: bot.id)
                ForEach(list) { routine in
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
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            }
        }
    }

    @ViewBuilder
    private var screenLabel: some View {
        if computer?.controlHolder == .user {
            Text("Open in full window")
        } else if computer?.kind == .desktop {
            Text("This bot runs on this computer, not a Linux desktop. Shell and files use your home folder.")
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
        if computer?.controlHolder == .user { return "You have control" }
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

            GrizzyField(placeholder: "Name this bot", text: $createName)
                .padding(.top, 24)
            GrizzyField(placeholder: "Describe what this bot does", text: $createTitle)
                .padding(.top, 12)
            GrizzyField(
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

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        store.updateBot(
                            botId: bot.id,
                            name: settingsName,
                            title: settingsTitle,
                            description: settingsDescription,
                            instructions: settingsDescription
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

    private func syncSettings() {
        guard let bot, settingsLoadedFor != bot.id else { return }
        settingsName = bot.name
        settingsTitle = bot.title
        settingsDescription = bot.description
        settingsLoadedFor = bot.id
        confirmDelete = false
        settingsError = nil
    }

    private func exportBot(_ bot: Bot) {
        guard let manifest = store.exportManifest(botId: bot.id) else { return }
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
            GrizzyField(
                label: "Instruction",
                labelSize: 14,
                placeholder: "Instruction",
                text: Binding(
                    get: { store.routineDraft.prompt },
                    set: { store.routineDraft.prompt = $0 }
                ),
                axis: .vertical,
                lineLimit: 4...8
            )
            .padding(.top, 12)

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
                if let bot {
                    store.saveRoutineDraft(botId: bot.id)
                }
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
            .padding(.top, 20)
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
