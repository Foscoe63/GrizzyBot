import GrizzyBotCore
import SwiftUI

/// What this bot remembers, one fact at a time: where it came from, and a way to pin, vouch for, or delete it.
struct MemoryTimelineView: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var expanded = false

    var body: some View {
        let items = store.memoryItems(botId: botId)
        let flagged = items.filter(\.untrusted).count
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text("What I remember (\(items.count))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    if flagged > 0 {
                        Text("\(flagged) unverified")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.orange)
                    }
                    Spacer()
                    Text(expanded ? "Hide" : "Show")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textGhost)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if items.isEmpty {
                    Text("Nothing yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.display)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textBright)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(caption(item))
                                .font(.system(size: 11.5))
                                .foregroundStyle(item.untrusted ? Theme.orange : Theme.textMuted)
                        }
                        Spacer(minLength: 6)
                        if item.untrusted {
                            small("Trust") { store.trustMemoryItem(botId: botId, item) }
                        }
                        small(item.pinned ? "Unpin" : "Pin") {
                            store.setMemoryItemPinned(botId: botId, item, pinned: !item.pinned)
                        }
                        small("Delete", danger: true) { store.deleteMemoryItem(botId: botId, item) }
                    }
                    .padding(.vertical, 3)
                }
                Text("Unverified facts were saved after the bot read a web page, email, or plugin result. Trust keeps one; Delete removes it for good.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func caption(_ item: MemoryItem) -> String {
        var parts = [item.shared ? "shared with every bot" : "this bot"]
        if item.pinned { parts.append("pinned — always loaded") }
        if item.untrusted { parts.append("unverified — saved after reading outside content") }
        return parts.joined(separator: " · ")
    }

    private func small(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(danger ? Theme.orange : Theme.textGhost)
        }
        .buttonStyle(.plain)
    }
}
