import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

/// Review a team before anything is created: pick departments, see which accounts it wants.
/// Every way of opening a team (file, link, drop, library, double-click) ends up here.
struct TeamReviewSheet: View {
    @Environment(AppStore.self) private var store
    let package: TeamPackage

    @State private var chosen: Set<String> = []
    @State private var includeUngrouped = true
    @State private var created: [Bot]?

    private var hasDepartments: Bool { !package.departments.isEmpty }
    private var ungrouped: [TeamPackage.BotSpec] { package.ungroupedBots }
    private var nothingChosen: Bool { hasDepartments && chosen.isEmpty && !(includeUngrouped && !ungrouped.isEmpty) }
    private var effective: TeamPackage {
        hasDepartments ? package.restricted(toDepartments: Array(chosen), includeUngrouped: includeUngrouped) : package
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(created == nil ? "Import “\(package.name)”?" : "“\(package.name)” is ready")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            if !package.summary.isEmpty {
                Text(package.summary).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let created { doneBody(created) } else { reviewBody }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            HStack {
                Spacer()
                if created == nil {
                    Button("Cancel") { store.dismissPendingTeam() }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    GrizzyButton(title: "Import", variant: .cream, size: .sm, disabled: nothingChosen) {
                        created = store.confirmPendingTeam(departments: hasDepartments ? Array(chosen) : nil, includeUngrouped: includeUngrouped)
                    }
                } else {
                    GrizzyButton(title: "Done", variant: .cream, size: .sm) { store.dismissPendingTeam() }
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bgRightPanel)
        .onAppear { chosen = Set(package.departments.map(\.name)) }
    }

    @ViewBuilder private var reviewBody: some View {
        if hasDepartments {
            section("Departments") {
                ForEach(package.departments, id: \.name) { dept in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(dept.name) },
                        set: { on in if on { chosen.insert(dept.name) } else { chosen.remove(dept.name) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dept.name).foregroundStyle(Theme.textBright)
                            Text(dept.bots.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !ungrouped.isEmpty {
                    Toggle(isOn: $includeUngrouped) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Everyone else").foregroundStyle(Theme.textBright)
                            Text(ungrouped.map(\.name).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        section("This will add") {
            Text(effective.preview())
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
        connectorSection
    }

    private func doneBody(_ made: [Bot]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Added \(made.count) bot\(made.count == 1 ? "" : "s"): \(made.map(\.name).joined(separator: ", ")). Routines are paused and bots ask before they act.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            connectorSection
            if !store.connectorChecklist(for: package).missing.isEmpty {
                GrizzyButton(title: "Open connections", variant: .cream, size: .sm) {
                    store.dismissPendingTeam()
                    store.openPlugins()
                }
            }
        }
    }

    @ViewBuilder private var connectorSection: some View {
        if !package.connectors.isEmpty {
            let list = store.connectorChecklist(for: package)
            section("Accounts") {
                ForEach(list.connected, id: \.slug) { c in row(c, done: true) }
                ForEach(list.missing, id: \.slug) { c in row(c, done: false) }
                Text("Nothing is connected for you. Connect these from Connections when you want them.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func row(_ c: TeamPackage.ConnectorSpec, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name + (c.required && !done ? " (needed)" : "")).foregroundStyle(Theme.textBright)
                if !c.why.isEmpty { Text(c.why).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
            content()
        }
    }
}

/// Choose bots, label departments, and pick accounts to suggest, then save one shareable file.
struct TeamExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var summary = ""
    @State private var included: Set<String> = []
    @State private var departmentOf: [String: String] = [:]
    @State private var accounts: Set<String> = []
    @State private var neededAccounts: Set<String> = []
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export team").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textBright)
            GrizzyField(label: "Team name", placeholder: "My team", text: $name)
            GrizzyField(label: "What is it for?", placeholder: "One line for whoever imports it", text: $summary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("BOTS AND DEPARTMENTS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    ForEach(store.visibleBots) { bot in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { included.contains(bot.id) },
                                set: { on in if on { included.insert(bot.id) } else { included.remove(bot.id) } }
                            )) { Text(bot.name).foregroundStyle(Theme.textBright) }
                            .toggleStyle(.checkbox)
                            Spacer()
                            TextField("Department", text: Binding(
                                get: { departmentOf[bot.id] ?? "" },
                                set: { departmentOf[bot.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .disabled(!included.contains(bot.id))
                        }
                    }
                    if !store.connectableAccounts.isEmpty {
                        Text("ACCOUNTS TO SUGGEST").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                        ForEach(store.connectableAccounts, id: \.slug) { account in
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { accounts.contains(account.slug) },
                                    set: { on in if on { accounts.insert(account.slug) } else { accounts.remove(account.slug); neededAccounts.remove(account.slug) } }
                                )) { Text(account.name).foregroundStyle(Theme.textBright) }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Toggle("Needed", isOn: Binding(
                                    get: { neededAccounts.contains(account.slug) },
                                    set: { on in if on { neededAccounts.insert(account.slug) } else { neededAccounts.remove(account.slug) } }
                                ))
                                .toggleStyle(.checkbox)
                                .foregroundStyle(Theme.textSecondary)
                                .disabled(!accounts.contains(account.slug))
                            }
                        }
                        Text("Only the service name is shared, never a login or token.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if let notice { Text(notice).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                GrizzyButton(title: "Save…", variant: .cream, size: .sm, disabled: included.isEmpty) { save() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.bgRightPanel)
        .onAppear { included = Set(store.visibleBots.map(\.id)) }
    }

    private func save() {
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "My team" : name
        let connectors = store.connectableAccounts
            .filter { accounts.contains($0.slug) }
            .map { TeamPackage.ConnectorSpec(slug: $0.slug, name: $0.name, required: neededAccounts.contains($0.slug)) }
        let package = store.exportTeamPackage(
            name: title, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            botIds: Array(included), connectors: connectors, departmentByBotId: departmentOf
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".team.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try package.markdown().write(to: url, atomically: true, encoding: .utf8)
            notice = "Saved \(url.lastPathComponent)."
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Browse teams that ship with GrizzyBot, and any library you point it at.
struct TeamLibrarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var libraryURL = ""
    @State private var online: [TeamLibraryEntry] = []
    @State private var status: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Team library").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textBright)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("BUILT IN").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    ForEach(TeamLibrary.starters, id: \.name) { team in
                        entryRow(TeamLibrary.entry(for: team)) { open(team) }
                    }
                    Text("ONLINE").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted).padding(.top, 6)
                    HStack {
                        GrizzyField(placeholder: "https://example.com/teams/index.json", text: $libraryURL, onCommit: { loadIndex() })
                        GrizzyButton(title: loading ? "Loading…" : "Load", variant: .cream, size: .sm, disabled: loading) { loadIndex() }
                    }
                    ForEach(online) { entry in
                        entryRow(entry) { fetchAndOpen(entry) }
                    }
                    if let status { Text(status).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary) }
                    Text("A library is a JSON file listing team files (format grizzybot-team-index/1). Anyone can host one. You always review a team before it is imported.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary) }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.bgRightPanel)
        .onAppear {
            libraryURL = store.appConfig.teamLibraryURL
            if !libraryURL.isEmpty { loadIndex() }
        }
    }

    private func entryRow(_ entry: TeamLibraryEntry, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textBright)
                if !entry.summary.isEmpty { Text(entry.summary).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary) }
                let detail = ([entry.bots > 0 ? "\(entry.bots) bot\(entry.bots == 1 ? "" : "s")" : nil] + entry.tags.map { Optional($0) }).compactMap { $0 }
                if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
            Spacer()
            GrizzyButton(title: "Review…", variant: .cream, size: .sm, action: action)
        }
    }

    /// Closes this sheet first so the review sheet can take its place.
    private func present(_ package: TeamPackage) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.proposeTeam(package) }
    }

    private func open(_ package: TeamPackage) { present(package) }

    private func loadIndex() {
        let text = libraryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = store.appConfig
        config.teamLibraryURL = text
        store.saveAppConfig(config)
        guard !text.isEmpty else { online = []; status = nil; return }
        guard let url = URL(string: text) else { status = "That isn't a valid address."; return }
        loading = true
        status = nil
        Task { @MainActor in
            defer { loading = false }
            do {
                online = try await TeamLibraryIndex.fetch(url: url).teams
                if online.isEmpty { status = "That library has no teams." }
            } catch {
                online = []
                status = error.localizedDescription
            }
        }
    }

    private func fetchAndOpen(_ entry: TeamLibraryEntry) {
        guard let raw = entry.url, let url = URL(string: raw) else { status = "“\(entry.name)” has no download address."; return }
        status = "Fetching “\(entry.name)”…"
        Task { @MainActor in
            do {
                present(try await TeamPackage.fetch(url: url))
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

/// Handles a team file arriving from outside the Teams settings (double-click, Open With, Dock drop).
@MainActor
enum TeamFileOpener {
    static func open(_ url: URL, store: AppStore) {
        do {
            try store.proposeTeam(file: url)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
