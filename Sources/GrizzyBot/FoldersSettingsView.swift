import AppKit
import GrizzyBotCore
import SwiftUI

/// Settings → Folders: host folders bots can read and write once assigned (per bot, in its settings).
struct FoldersSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Granted folders")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text("Folders GrizzyBot may read and write without asking each time. A folder does nothing until you assign it to a bot, in that bot's settings. Secrets such as .ssh and .env files stay blocked.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.grantedFolders.isEmpty {
                Text("No folders yet. Choose one below.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.grantedFolders) { folder in
                        row(folder)
                    }
                }
            }

            HStack(spacing: 10) {
                GrizzyButton(title: "Add folder…", variant: .cream, size: .sm) { pickFolder() }
                if let notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
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

    private func row(_ folder: GrantedFolder) -> some View {
        let assigned = store.bots.filter { $0.grantedFolderIds.contains(folder.id) }
        let exists = FileManager.default.fileExists(atPath: BotHomeStore.expandPath(folder.path))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Text(folder.path)
                        .font(.system(size: 12))
                        .foregroundStyle(exists ? Theme.textMuted : Theme.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Remove") {
                    store.removeGrantedFolder(folder.id)
                    notice = "Removed \(folder.name)."
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.orange)
            }
            Text(assigned.isEmpty
                 ? "Not assigned to any bot"
                 : "Read/write for " + assigned.map(\.name).joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(assigned.isEmpty ? Theme.textMuted : Theme.green)
            if !exists {
                Text("This folder no longer exists on disk.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Grant access"
        panel.message = "Folders GrizzyBot bots may read and write"
        guard panel.runModal() == .OK else { return }
        var added = 0
        for url in panel.urls where store.addGrantedFolder(path: url.path) != nil { added += 1 }
        notice = added == panel.urls.count ? nil : "Some folders were skipped (protected location)."
    }
}
