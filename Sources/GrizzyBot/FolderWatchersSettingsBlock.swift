import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

struct FolderWatchersSettingsBlock: View {
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
