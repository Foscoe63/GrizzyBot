import GrizzyBotCore
import SwiftUI

struct PluginsOverlayView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""

    private var filtered: [ConnectionItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.connections }
        return store.connections.filter {
            $0.name.lowercased().contains(q) || $0.slug.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 4 / 255, green: 4 / 255, blue: 5 / 255).opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { store.pluginsOpen = false }

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plugins")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Theme.textBrightAlt)
                        Text("\(store.connections.count) apps")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textPluginsSub)
                    }
                    Spacer()
                    Button {
                        store.pluginsOpen = false
                    } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                TextField("Search apps", text: $search)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textBright)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(hex: "#101012"))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Theme.borderInputsDark, lineWidth: 1)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 16)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { item in
                            pluginRow(item)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                }
                .grizzyScroll()
                .frame(maxHeight: .infinity)
            }
            .frame(width: min(1080, 1080), height: min(760, 760))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgPluginsCard)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 12)
            .padding(40)
        }
    }

    private func pluginRow(_ item: ConnectionItem) -> some View {
        let pending = store.connectionPending.contains(item.slug)
        return HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.bgPluginLogo)
                    .frame(width: 42, height: 42)
                Text(String(item.name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Text(item.noAuth ? "\(item.slug) · no auth" : item.slug)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPluginsSub)
            }
            Spacer()
            Button {
                if item.connected {
                    store.revoke(slug: item.slug)
                } else {
                    store.connect(slug: item.slug)
                }
            } label: {
                Text(
                    pending
                        ? (item.connected ? "Revoking…" : "Connecting…")
                        : (item.connected ? "Revoke" : "Connect")
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPill)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.bgDarkButtonAlt)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(pending)
            .opacity(pending ? 0.55 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
