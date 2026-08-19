import AppKit
import GrizzyBotCore
import SwiftUI

struct PluginsOverlayView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var tokenDraft = ""
    @State private var toolkitSlug = ""
    @State private var browseTask: Task<Void, Never>?

    private var filtered: [ConnectionItem] {
        PluginCatalogFilter.filter(store.connections, query: search)
    }

    private var catalogToAdd: [ConnectionItem] {
        let known = Set(store.connections.map(\.slug))
        return store.composioCatalog.filter { !known.contains($0.slug) }
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
                        Text("\(store.connections.count) apps in GrizzyBot")
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

                oauthBanner
                    .padding(.horizontal, 32)
                    .padding(.top, 14)

                if let err = store.pluginError {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#E8A07A"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.top, 10)
                }

                TextField("Search apps or Composio toolkits", text: $search)
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

                addToolkitRow
                    .padding(.horizontal, 32)
                    .padding(.top, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        sectionHeader("Your apps")
                        if filtered.isEmpty {
                            Text(search.isEmpty ? "No apps in GrizzyBot yet." : "No installed apps match that search.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(filtered) { item in
                                pluginRow(item)
                            }
                        }

                        catalogSection
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
            .accessibilityIdentifier(OverlayA11y.plugins)
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 12)
            .padding(40)
        }
        .accessibilityIdentifier(OverlayA11y.plugins)
        .accessibilityElement(children: .contain)
        .onAppear { store.openPlugins() }
        .onChange(of: search) { _, query in
            scheduleBrowse(query)
        }
        .onDisappear {
            browseTask?.cancel()
        }
        .onChange(of: store.pluginAuthURL) { _, url in
            if let url { NSWorkspace.shared.open(url) }
        }
        .sheet(isPresented: Binding(
            get: { store.connectingSlug != nil },
            set: { if !$0 { store.connectingSlug = nil; tokenDraft = "" } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect \(store.connectingSlug ?? "")")
                    .font(.system(size: 18, weight: .medium))
                Text(PluginClient.tokenHint(for: store.connectingSlug ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                SecureField("API token or webhook URL", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                if let err = store.pluginError {
                    Text(err).font(.system(size: 12)).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") {
                        store.connectingSlug = nil
                        tokenDraft = ""
                    }
                    Spacer()
                    Button("Connect") {
                        if let slug = store.connectingSlug {
                            store.connect(slug: slug, token: tokenDraft)
                        }
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
    }

    private var addToolkitRow: some View {
        HStack(spacing: 10) {
            TextField("Add toolkit slug (clickup, hubspot, …)", text: $toolkitSlug)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textBright)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "#101012"))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.borderInputsDark, lineWidth: 1)
                }
                .onSubmit { addSlug() }

            Button("Add") {
                addSlug()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPill)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.bgDarkButtonAlt)
            .clipShape(Capsule())
            .disabled(toolkitSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(toolkitSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        HStack {
            sectionHeader("Composio catalog")
            Spacer()
            if store.composioCatalogLoading {
                ProgressView()
                    .controlSize(.small)
            } else if store.pluginsUseOAuth {
                Button("Refresh") {
                    Task { await store.browseComposioCatalog(query: search) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textGhost)
            }
        }
        .padding(.top, 18)

        if !store.pluginsUseOAuth {
            Text("Add a Composio Connect key in Settings to browse 200+ toolkits, or type a slug above.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 6)
        } else if let err = store.composioCatalogError {
            Text(err)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "#E8A07A"))
                .padding(.vertical, 6)
        } else if store.composioCatalogLoading {
            Text("Loading toolkits…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 6)
        } else if catalogToAdd.isEmpty {
            Text(search.isEmpty ? "Search to find more Composio toolkits, or add a slug above." : "No more Composio toolkits match that search.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 6)
        } else {
            ForEach(catalogToAdd) { item in
                catalogRow(item)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .textCase(.uppercase)
            .padding(.bottom, 4)
    }

    private func scheduleBrowse(_ query: String) {
        browseTask?.cancel()
        guard store.pluginsUseOAuth else { return }
        browseTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.browseComposioCatalog(query: query)
        }
    }

    private func addSlug() {
        let slug = toolkitSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.addToolkit(slug: slug) != nil else { return }
        toolkitSlug = ""
        search = ""
    }

    private func catalogRow(_ item: ConnectionItem) -> some View {
        HStack(spacing: 16) {
            pluginLogo(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Text(item.blurb.isEmpty ? item.slug : item.blurb)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPluginsSub)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                _ = store.addToolkit(item)
            } label: {
                Text("Add")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.bgDarkButtonAlt)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var oauthBanner: some View {
        if store.pluginsUseOAuth {
            Text("Connect opens a browser sign-in via Composio. Paste a token instead if you already have one.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPluginsSub)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Text("Add a Composio Connect key in Settings to sign in through the browser. Until then, paste an API token per app.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPluginsSub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Settings") {
                    store.pluginsOpen = false
                    store.openAppSettings(section: .connections)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textGhost)
            }
        }
    }

    private func pluginRow(_ item: ConnectionItem) -> some View {
        let pending = store.connectionPending.contains(item.slug)
        let waiting = store.oauthWaitSlug == item.slug
        return HStack(spacing: 16) {
            pluginLogo(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Text(rowSubtitle(item, waiting: waiting))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPluginsSub)
                    .lineLimit(1)
            }
            Spacer()
            if !item.connected && !item.noAuth {
                Button("Paste token") {
                    store.promptPluginToken(slug: item.slug)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            }
            Button {
                if item.connected {
                    store.revoke(slug: item.slug)
                } else {
                    store.connect(slug: item.slug)
                }
            } label: {
                Text(rowAction(item, pending: pending, waiting: waiting))
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

    private func rowSubtitle(_ item: ConnectionItem, waiting: Bool) -> String {
        if waiting { return "Waiting for sign-in in the browser…" }
        if item.connected {
            if let label = item.accountLabel, !label.isEmpty { return label }
            return item.viaComposio ? "Signed in" : "Connected"
        }
        if item.noAuth { return "\(item.slug) · no auth" }
        if !item.blurb.isEmpty { return item.blurb }
        if store.pluginsUseOAuth { return "Sign in with your account" }
        return PluginClient.tokenHint(for: item.slug)
    }

    private func rowAction(_ item: ConnectionItem, pending: Bool, waiting: Bool) -> String {
        if waiting { return "Waiting…" }
        if pending { return item.connected ? "Revoking…" : "Connecting…" }
        return item.connected ? "Revoke" : "Connect"
    }

    @ViewBuilder
    private func pluginLogo(_ item: ConnectionItem) -> some View {
        let remote = item.logo.flatMap(URL.init(string:)) ?? item.faviconURL
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.bgPluginLogo)
                .frame(width: 42, height: 42)
            if let remote {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    default:
                        Text(String(item.name.prefix(1)))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textBright)
                    }
                }
            } else {
                Text(String(item.name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
            }
        }
    }
}
