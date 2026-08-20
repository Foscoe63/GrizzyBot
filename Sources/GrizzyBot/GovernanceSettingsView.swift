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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Folder corpora stay on this Mac. Plugin sources (Google Drive, OneDrive, Box) sync through the connected account on search, then BM25. Empty grant list means every bot. ACL is grantedBotIds on the source.")
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
            GrizzyButton(title: "Add folder source", variant: .cream, size: .sm) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !folder.isEmpty else { return }
                store.addKnowledgeSource(KnowledgeSource(name: trimmed, kind: .folder, path: folder))
                name = ""
                path = ""
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        Text("\(source.kind.rawValue) · \(source.path)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Remove") {
                        store.removeKnowledgeSource(source.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.orange)
                    .disabled(!store.isOwner)
                }
                .padding(.vertical, 6)
            }
            if store.knowledgeSources.isEmpty {
                Text("No knowledge sources yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
        }
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
