import AppKit
import GrizzyBotCore
import SwiftUI

struct GovernanceSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var denyText = ""
    @State private var allowText = ""
    @State private var mode: PolicyMode = .enforce
    @State private var stallMs = "60000"
    @State private var auditText = ""
    @State private var auditVerdict: String?
    @State private var auditAllowed: AuditAllowedFilter = .any
    @State private var auditTypeRaw = ""

    private enum AuditAllowedFilter: String, CaseIterable, Identifiable {
        case any, allowed, refused
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any"
            case .allowed: return "Allowed"
            case .refused: return "Refused"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.currentRole.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.isOwner ? Theme.textBright : Theme.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.bgCard)
                    .clipShape(Capsule())
                Text(store.isOwner
                     ? "Owner can save policy, grants, knowledge, and components for this Mac."
                     : "Operator: policy is read-only. Ask the owner to change grants or CEL.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }

            settingsIntro(
                title: "Action policy",
                subtitle: "Deny-before-allow CEL. A broken deny still denies; a broken allow does not permit. Empty allow permits nothing. Dry run records refusals and still forwards. Click rules use the last screenshot’s element.name / element.role, not the model’s label."
            )
            Picker("Mode", selection: $mode) {
                ForEach(PolicyMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!store.isOwner)
            VStack(alignment: .leading, spacing: 6) {
                Text("Deny (one expression per line)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $denyText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(!store.isOwner)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow (one expression per line)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $allowText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(!store.isOwner)
            }
            GrizzyButton(title: "Save policy", variant: .cream, size: .sm) {
                store.setActionPolicy(
                    ActionPolicy(
                        mode: mode,
                        deny: lines(denyText),
                        allow: lines(allowText)
                    )
                )
            }
            .opacity(store.isOwner ? 1 : 0.4)
            .disabled(!store.isOwner)
            Text("Examples: `contains(element.name, \"Submit\")`, `intent == \"write_tool\"`, `contains(page.host, \"bank\")`, `mcp.effect == \"write\"`. Functions: contains, matches.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)

            settingsIntro(
                title: "MCP grants",
                subtitle: "Bot × server. Empty matrix allows every enabled MCP server. The first revoke switches that bot to an allow-list. Effect uses tools advertised on the last mcp_list_tools, not a vendor name guess."
            )
            if store.mcpServers.isEmpty {
                Text("Add MCP servers in Settings → Tools.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(store.bots) { bot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bot.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        ForEach(store.mcpServers) { server in
                            Toggle(isOn: Binding(
                                get: { store.isPluginGranted(botId: bot.id, plugin: server.toolId) },
                                set: { store.setPluginGranted(botId: bot.id, plugin: server.toolId, granted: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.system(size: 13))
                                    if let tools = store.mcpAdvertisedTools[server.id], !tools.isEmpty {
                                        Text(tools.joined(separator: ", "))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .disabled(!store.isOwner)
                            if let tools = store.mcpAdvertisedTools[server.id], !tools.isEmpty {
                                ForEach(tools, id: \.self) { toolName in
                                    Toggle(isOn: Binding(
                                        get: { store.isPluginGranted(botId: bot.id, plugin: server.toolId, tool: toolName) },
                                        set: { store.setPluginGranted(botId: bot.id, plugin: server.toolId, tool: toolName, granted: $0) }
                                    )) {
                                        Text(toolName)
                                            .font(.system(size: 12, design: .monospaced))
                                    }
                                    .padding(.leading, 18)
                                    .disabled(!store.isOwner)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            settingsIntro(
                title: "Stall watchdog",
                subtitle: "Ends a turn when the model stream goes silent. 0 disables. Default 60000 ms."
            )
            GrizzyField(placeholder: "60000", text: $stallMs)
                .disabled(!store.isOwner)
            GrizzyButton(title: "Save stall timeout", variant: .cream, size: .sm) {
                let value = Int(stallMs.trimmingCharacters(in: .whitespaces)) ?? 60_000
                store.setStallTimeout(max(0, value))
            }
            .opacity(store.isOwner ? 1 : 0.4)
            .disabled(!store.isOwner)

            settingsIntro(
                title: "Audit trail",
                subtitle: "Queryable log of the last 2,000 events, including the live boot boundary (policy loaded + computer isolation)."
            )
            HStack(spacing: 10) {
                GrizzyButton(title: "Verify audit trail", variant: .cream, size: .sm) {
                    auditVerdict = AuditChain.verify(store.auditEvents).summary
                }
                if let auditVerdict {
                    Text(auditVerdict)
                        .font(.system(size: 12.5))
                        .foregroundStyle(auditVerdict.contains("broken") ? Theme.orange : Theme.textSecondary)
                }
            }
            GrizzyField(placeholder: "Search type, bot, reason…", text: $auditText)
            HStack {
                Picker("Result", selection: $auditAllowed) {
                    ForEach(AuditAllowedFilter.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                TextField("type e.g. computer.action_refused", text: $auditTypeRaw)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
            }
            let queried = AuditLog.query(store.auditEvents, AuditLog.Query(
                type: AuditEventType(rawValue: auditTypeRaw.trimmingCharacters(in: .whitespaces)),
                allowed: auditAllowed == .any ? nil : auditAllowed == .allowed,
                text: auditText,
                limit: 40
            ))
            ForEach(queried) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(event.type.rawValue)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(event.allowed == false ? Theme.orange : Theme.textBright)
                    Text(event.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
            }
            if queried.isEmpty {
                Text(store.auditEvents.isEmpty ? "No audit events yet." : "No events match that query.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .onAppear {
            denyText = store.actionPolicy.deny.joined(separator: "\n")
            allowText = store.actionPolicy.allow.joined(separator: "\n")
            mode = store.actionPolicy.mode
            stallMs = String(store.appConfig.agentStallTimeoutMs)
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func settingsIntro(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct KnowledgeSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var path = ""
    @State private var pluginSlug = ""
    @State private var roots = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Folder corpora stay on this Mac. Plugin sources (Google Drive, OneDrive, Box) sync through the connected account on search, then BM25. Add as many sources as you like. Each one can be limited to specific subfolders and specific bots; with no bots selected, every bot can search it.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            if !store.isOwner {
                Text("Only the owner can add or remove knowledge sources.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }

            GrizzyField(placeholder: "Source name", text: $name)
                .disabled(!store.isOwner)
            GrizzyField(placeholder: "Folder path (~/Documents/Policies)", text: $path)
                .disabled(!store.isOwner)
            GrizzyField(placeholder: "Subfolders (optional, comma-separated: Policies, HR/2026)", text: $roots)
                .disabled(!store.isOwner)
            GrizzyButton(title: "Add folder source", variant: .cream, size: .sm) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !folder.isEmpty else { return }
                store.addKnowledgeSource(
                    KnowledgeSource(
                        name: trimmed,
                        kind: .folder,
                        path: folder,
                        roots: KnowledgeSourceRow.parseRoots(roots)
                    )
                )
                name = ""
                path = ""
                roots = ""
            }
            .disabled(!store.isOwner)
            .opacity(store.isOwner ? 1 : 0.4)

            GrizzyField(placeholder: "Plugin slug (google-drive, microsoft-onedrive, box)", text: $pluginSlug)
                .disabled(!store.isOwner)
            GrizzyButton(title: "Add plugin source", variant: .cream, size: .sm) {
                let slug = pluginSlug.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !slug.isEmpty else { return }
                store.addKnowledgeSource(
                    KnowledgeSource(name: slug, kind: .plugin, path: slug)
                )
                pluginSlug = ""
            }
            .disabled(!store.isOwner)
            .opacity(store.isOwner ? 1 : 0.4)

            ForEach(store.knowledgeSources) { source in
                KnowledgeSourceRow(source: source)
            }
            if store.knowledgeSources.isEmpty {
                Text("No knowledge sources yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .task { await store.refreshKnowledgeStats() }
    }
}

struct KnowledgeSourceRow: View {
    @Environment(AppStore.self) private var store
    let source: KnowledgeSource
    @State private var expanded = false
    @State private var rootsText = ""
    @State private var testQuery = ""
    @State private var testBotId = ""
    @State private var testHits: [KnowledgeHit]?
    @State private var testing = false

    static func parseRoots(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var botSummary: String {
        if source.grantedBotIds.isEmpty { return "all bots" }
        let names = store.bots.filter { source.grantedBotIds.contains($0.id) }.map(\.name)
        return names.isEmpty ? "no matching bots" : names.joined(separator: ", ")
    }

    private var detail: String {
        var parts = [source.kind.rawValue, source.path]
        if source.kind == .folder, !source.roots.isEmpty {
            parts.append("subfolders: " + source.roots.joined(separator: ", "))
        }
        parts.append("bots: " + botSummary)
        if !source.enabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }

    private var stats: KnowledgeIndexStats? { store.knowledgeStats[source.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { store.updateKnowledgeSource(source.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(source.enabled ? "Turn this source off without deleting it" : "Turn this source back on")
                .disabled(!store.isOwner)
                Button(expanded ? "Done" : "Edit") {
                    expanded.toggle()
                    rootsText = source.roots.joined(separator: ", ")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Button("Remove") {
                    store.removeKnowledgeSource(source.id)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.orange)
                .disabled(!store.isOwner)
            }
            if source.kind == .folder, source.enabled, let stats {
                Text(stats.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(stats.skippedFiles > 0 ? Theme.orange : Theme.textMuted)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let stats, source.enabled {
                        ForEach(stats.notes, id: \.self) { note in
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.orange)
                        }
                    }
                    if source.kind == .folder {
                        GrizzyField(
                            label: "Subfolders",
                            placeholder: "Blank indexes the whole folder. Comma-separated, relative to the path.",
                            text: $rootsText,
                            onCommit: saveRoots
                        )
                        .disabled(!store.isOwner)
                        GrizzyButton(title: "Save subfolders", variant: .outline, size: .sm, action: saveRoots)
                            .disabled(!store.isOwner)
                    }
                    Text("Bots that can search this source")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Select none to allow every bot.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                    ForEach(store.bots) { bot in
                        Toggle(bot.name, isOn: botBinding(bot.id))
                            .toggleStyle(.checkbox)
                            .foregroundStyle(Theme.textBright)
                            .disabled(!store.isOwner)
                    }
                    if source.kind == .folder {
                        GrizzyButton(title: "Re-index from scratch", variant: .outline, size: .sm) {
                            Task { await store.refreshKnowledgeStats(rebuild: source.id) }
                        }
                        .disabled(!source.enabled)
                    }
                    testSearchPanel
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private var testSearchPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test search")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Picker("Search as", selection: $testBotId) {
                Text("Owner (ignore bot access)").tag("")
                ForEach(store.bots) { bot in
                    Text(bot.name).tag(bot.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            GrizzyField(placeholder: "Try a question a bot might ask", text: $testQuery, onCommit: runTest)
            GrizzyButton(title: testing ? "Searching…" : "Search", variant: .outline, size: .sm, action: runTest)
                .disabled(testing || testQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            if !testBotId.isEmpty {
                Text(source.enabled && source.allows(botId: testBotId)
                    ? "This bot can search \(source.name)."
                    : "This bot cannot search \(source.name).")
                    .font(.system(size: 12))
                    .foregroundStyle(source.enabled && source.allows(botId: testBotId) ? Theme.textMuted : Theme.orange)
            }
            if let testHits {
                if testHits.isEmpty {
                    Text("No hits.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                ForEach(Array(testHits.enumerated()), id: \.offset) { _, hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(hit.sourceName) · \(hit.title)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        Text(scoreLine(hit))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                        Text(hit.snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(4)
                        if !hit.linked.isEmpty {
                            Text("Links: " + hit.linked.joined(separator: ", "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func scoreLine(_ hit: KnowledgeHit) -> String {
        var parts = [String(format: "score %.2f", hit.score)]
        if hit.keywordScore > 0 { parts.append(String(format: "keyword %.2f", hit.keywordScore)) }
        if let semantic = hit.semanticScore { parts.append(String(format: "semantic %.2f", semantic)) }
        parts.append(hit.relativePath.isEmpty ? hit.path : hit.relativePath)
        return parts.joined(separator: " · ")
    }

    private func runTest() {
        let query = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !testing else { return }
        testing = true
        Task {
            let hits = await store.knowledgeTestSearch(query: query, asBot: testBotId.isEmpty ? nil : testBotId)
            testHits = hits
            testing = false
        }
    }

    private func saveRoots() {
        store.updateKnowledgeSource(source.id, roots: Self.parseRoots(rootsText))
    }

    private func botBinding(_ botId: String) -> Binding<Bool> {
        Binding(
            get: { source.grantedBotIds.contains(botId) },
            set: { on in
                var ids = source.grantedBotIds
                ids.removeAll { $0 == botId }
                if on { ids.append(botId) }
                store.updateKnowledgeSource(source.id, grantedBotIds: ids)
            }
        )
    }
}

struct ComponentsSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var title = ""
    @State private var kind = "form"
    @State private var sourceJSON = """
    {"id":"custom","title":"Custom","fields":[{"id":"f1","label":"Name","value":""}],"items":[]}
    """
    @State private var preview: ComponentPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Built-in cards: form, gallery, activity, refusals. Authored cards stay drafts until you publish. activity/refusals need a component-data grant once any data grant exists for that bot.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            if !store.isOwner {
                Text("Only the owner can publish components.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }

            GrizzyField(placeholder: "Title", text: $title)
                .disabled(!store.isOwner)
            Picker("Kind", selection: $kind) {
                Text("form").tag("form")
                Text("gallery").tag("gallery")
            }
            .pickerStyle(.segmented)
            .disabled(!store.isOwner)
            TextEditor(text: $sourceJSON)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(!store.isOwner)
            HStack {
                GrizzyButton(title: "Preview", variant: .ghost, size: .sm) {
                    preview = decodePreview()
                }
                GrizzyButton(title: "Save draft", variant: .cream, size: .sm) {
                    guard store.isOwner else { return }
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    var component = SandboxComponent(
                        title: trimmed,
                        kind: kind,
                        sourceJSON: sourceJSON,
                        published: false
                    )
                    if let payload = decodePreview() {
                        component.sourceJSON = encode(payload) ?? sourceJSON
                    }
                    store.saveSandboxComponent(component)
                    title = ""
                }
                .disabled(!store.isOwner)
            }
            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    ForEach(preview.fields) { field in
                        Text("\(field.label): \(field.value)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(preview.items, id: \.self) { item in
                        Text("• \(item)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(10)
                .background(Theme.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            ForEach(store.sandboxComponents) { component in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(component.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        Text(component.published ? "Published · \(component.kind)" : "Draft · \(component.kind)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(component.published ? "Unpublish" : "Publish") {
                        store.publishSandboxComponent(component.id, published: !component.published)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSidebarIcon)
                    .disabled(!store.isOwner)
                    Button("Remove") {
                        store.removeSandboxComponent(component.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.orange)
                    .disabled(!store.isOwner)
                }
                .padding(.vertical, 6)
            }
            if store.sandboxComponents.isEmpty {
                Text("No authored components yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }

            settingsIntro(
                title: "Data function grants",
                subtitle: "activity and refusals read the audit log. Grant per bot once you start using the matrix."
            )
            ForEach(store.bots) { bot in
                VStack(alignment: .leading, spacing: 6) {
                    Text(bot.name)
                        .font(.system(size: 13, weight: .medium))
                    Toggle("activity", isOn: Binding(
                        get: { store.isPluginGranted(botId: bot.id, plugin: "component-data:activity") },
                        set: { store.setPluginGranted(botId: bot.id, plugin: "component-data:activity", granted: $0) }
                    ))
                    .disabled(!store.isOwner)
                    Toggle("refusals", isOn: Binding(
                        get: { store.isPluginGranted(botId: bot.id, plugin: "component-data:refusals") },
                        set: { store.setPluginGranted(botId: bot.id, plugin: "component-data:refusals", granted: $0) }
                    ))
                    .disabled(!store.isOwner)
                }
            }
        }
    }

    private func decodePreview() -> ComponentPayload? {
        guard let data = sourceJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ComponentPayload.self, from: data)
    }

    private func encode(_ payload: ComponentPayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func settingsIntro(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textBright)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
