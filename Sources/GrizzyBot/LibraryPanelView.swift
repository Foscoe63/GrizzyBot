import AppKit
import GrizzyBotCore
import SwiftUI

/// Everything the active bot has shared in this chat: artifacts, files it wrote, and links.
struct LibraryPanelView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: SharedItem.Kind?

    private var items: [SharedItem] {
        guard let botId = store.activeBotId else { return [] }
        let all = store.libraryItems(botId: botId)
        guard let filter else { return all }
        return all.filter { $0.kind == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text("Everything \(store.activeBot?.name ?? "this bot") has shared in this chat.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
            Picker("", selection: $filter) {
                Text("All").tag(SharedItem.Kind?.none)
                ForEach(SharedItem.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(SharedItem.Kind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let groups = BotLibrary.grouped(items)
            if groups.isEmpty {
                Text("Nothing yet. Artifacts, files, and links the bot shares will collect here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            }
            ForEach(groups, id: \.bucket) { group in
                Text(group.bucket.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 6)
                ForEach(group.items) { item in
                    Button { open(item) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(item.kind))
                                .foregroundStyle(Theme.textSub)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Theme.textBright)
                                    .lineLimit(1)
                                Text(item.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    private func icon(_ kind: SharedItem.Kind) -> String {
        switch kind {
        case .artifact: return "doc.richtext"
        case .file: return "doc"
        case .link: return "link"
        }
    }

    private func open(_ item: SharedItem) {
        switch item.kind {
        case .artifact:
            store.activeArtifactId = item.target
            store.openPanel(.artifact)
        case .file:
            let path = (item.target as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .link:
            if let url = URL(string: item.target) { NSWorkspace.shared.open(url) }
        }
    }
}
