import GrizzyBotCore
import SwiftUI

enum McpToolScope {
    case appDefaults
    case bot(String)
}

enum AgentToolGroup: String, CaseIterable, Identifiable {
    case files, web, memory, computer, canvas, artifacts, bots, skills, loop, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files & shell"
        case .web: return "Web"
        case .memory: return "Memory"
        case .computer: return "Computer"
        case .canvas: return "Canvas"
        case .artifacts: return "Artifacts"
        case .bots: return "Bots & plugins"
        case .skills: return "Skill tools"
        case .loop: return "Agent loop"
        case .custom: return "Custom"
        }
    }

    var toolIds: Set<String> {
        switch self {
        case .files:
            ["write_file", "read_file", "edit_file", "move_file", "delete_file", "list_files", "shell"]
        case .web:
            ["web_search"]
        case .memory:
            ["remember", "search_memory", "forget", "search_knowledge"]
        case .computer:
            [
                "request_takeover", "computer_screenshot", "computer_open",
                "computer_click", "computer_type", "computer_key", "computer_scroll",
            ]
        case .canvas:
            ["canvas_list", "canvas_open", "canvas_save", "canvas_delete", "canvas_place_image"]
        case .artifacts:
            [
                "artifact_create", "artifact_update", "artifact_rewrite",
                "artifact_list", "artifact_read", "artifact_delete",
            ]
        case .bots:
            [
                "spawn_bot", "message_bot", "delete_bot", "run_subagent", "destination_write",
                "plugin_call", "present_component", "report_decline",
            ]
        case .skills:
            ["read_skill", "import_skills", "capabilities_discover", "capabilities_load"]
        case .loop:
            ["todo", "complete", "clarify"]
        case .custom:
            []
        }
    }

    static func group(for tool: AgentToolDefinition) -> AgentToolGroup {
        if tool.kind == .custom { return .custom }
        return allCases.first { $0.toolIds.contains(tool.id) } ?? .files
    }
}

struct CapsuleSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.orange : Theme.bgChip)
            .frame(width: 40, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Theme.textCream)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .accessibilityHidden(true)
    }
}

struct ToolCapsuleToggle: View {
    let title: String
    var subtitle: String?
    var badge: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                CapsuleSwitch(isOn: isOn)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

struct McpStatusButton: View {
    let status: McpProbeStatus
    let cachedCount: Int
    let action: () -> Void

    private var fill: Color {
        switch status {
        case .connected: return Theme.green
        case .failed: return Theme.trafficRed
        case .checking: return Theme.trafficYellow
        case .idle: return Theme.textMuted
        }
    }

    private var label: String {
        switch status {
        case .connected(let count):
            return "Connected, \(count) tools. Click to recheck."
        case .failed(let reason):
            return "Not connected: \(reason). Click to retry."
        case .checking:
            return "Checking connection"
        case .idle:
            return cachedCount > 0
                ? "Not checked this session. \(cachedCount) tools last seen. Click to check."
                : "Not checked. Click to check connection."
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill.opacity(0.18))
                    .frame(width: 28, height: 28)
                if case .checking = status {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(fill)
                        .frame(width: 12, height: 12)
                }
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

struct McpServersToolsBlock: View {
    @Environment(AppStore.self) private var store
    var scope: McpToolScope
    var showsEditor: Bool = false
    var editingId: String?
    var onEdit: ((McpServer) -> Void)?
    var onDelete: ((McpServer) -> Void)?

    @State private var expandedIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.mcpServers.isEmpty {
                Text("No MCP servers yet. Add one below — GrizzyBot will probe it and show a green or red status.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(store.mcpServers) { server in
                serverCard(server)
            }
        }
        .onAppear { store.probeAllMcpServers() }
    }

    private func serverCard(_ server: McpServer) -> some View {
        let expanded = expandedIds.contains(server.id)
        let status = store.mcpStatus(for: server.id)
        let names = store.mcpToolNames(for: server.id)
        let parentOn = isServerEnabled(server)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                McpStatusButton(status: status, cachedCount: names.count) {
                    store.probeMcpServer(server.id)
                }
                Button {
                    toggleExpanded(server.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(server.name)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Theme.textBright)
                                .lineLimit(1)
                            Text(server.transport.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.orange.opacity(0.12))
                                .clipShape(Capsule())
                            Text(countLabel(status: status, names: names))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textGhost)
                                .lineLimit(1)
                            if editingId == server.id {
                                Text("editing")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.textGhost)
                            }
                            Spacer(minLength: 0)
                            Text(expanded ? "▾" : "▸")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Text(server.summaryLine)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(server.name), \(countLabel(status: status, names: names))")
                .accessibilityHint(expanded ? "Collapse tools" : "Expand tools")

                Button {
                    toggleServer(server)
                } label: {
                    CapsuleSwitch(isOn: parentOn)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(server.name) server")
                .accessibilityValue(parentOn ? "On" : "Off")
            }
            .padding(.vertical, 8)

            if showsEditor {
                HStack(spacing: 12) {
                    Spacer()
                    Button("Edit") { onEdit?(server) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textGhost)
                    Button("Delete") { onDelete?(server) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orange)
                }
                .padding(.bottom, expanded ? 0 : 4)
            }

            if expanded {
                expandedBody(server: server, status: status, names: names, parentOn: parentOn)
                    .padding(.leading, 38)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func expandedBody(
        server: McpServer,
        status: McpProbeStatus,
        names: [String],
        parentOn: Bool
    ) -> some View {
        switch status {
        case .checking:
            Text("Checking whether this server answers tools/list…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.trafficRed)
                    .fixedSize(horizontal: false, vertical: true)
                if names.isEmpty {
                    Text("No tools cached from a previous connection.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        case .idle:
            Text("Click the status light to check this server.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        case .connected:
            if names.isEmpty {
                Text("Connected, but this server advertised no tools.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(names, id: \.self) { name in
                    ToolCapsuleToggle(
                        title: name,
                        subtitle: store.mcpToolDescription(serverId: server.id, toolName: name),
                        isOn: isChildEnabled(server: server, name: name),
                        action: { toggleChild(server: server, name: name) }
                    )
                    .opacity(parentOn ? 1 : 0.45)
                }
            }
            if !parentOn {
                Text("Turn the server on to let bots call these tools.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 4)
            }
        }
    }

    private func countLabel(status: McpProbeStatus, names: [String]) -> String {
        switch status {
        case .connected(let count):
            return count == 1 ? "1 tool" : "\(count) tools"
        case .checking:
            return "checking…"
        case .failed:
            if names.isEmpty { return "offline" }
            return "offline · \(names.count) known"
        case .idle:
            if names.isEmpty { return "not checked" }
            return "\(names.count) known"
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }

    private func isServerEnabled(_ server: McpServer) -> Bool {
        switch scope {
        case .appDefaults:
            return store.appConfig.defaultEnabledTools.contains(server.toolId)
        case .bot(let botId):
            return store.bots.first(where: { $0.id == botId })?.isToolEnabled(server.toolId) == true
        }
    }

    private func isChildEnabled(server: McpServer, name: String) -> Bool {
        switch scope {
        case .appDefaults:
            return store.isDefaultMcpToolEnabled(serverId: server.id, toolName: name)
        case .bot(let botId):
            return store.isBotMcpToolEnabled(botId: botId, serverId: server.id, toolName: name)
        }
    }

    private func toggleServer(_ server: McpServer) {
        let next = !isServerEnabled(server)
        switch scope {
        case .appDefaults:
            store.setDefaultTool(server.toolId, enabled: next)
        case .bot(let botId):
            store.setBotTool(botId, toolId: server.toolId, enabled: next)
        }
    }

    private func toggleChild(server: McpServer, name: String) {
        let next = !isChildEnabled(server: server, name: name)
        switch scope {
        case .appDefaults:
            store.setDefaultMcpChildTool(serverId: server.id, toolName: name, enabled: next)
        case .bot(let botId):
            store.setBotMcpChildTool(botId: botId, serverId: server.id, toolName: name, enabled: next)
        }
    }
}

struct GroupedBuiltinToolsList: View {
    @Environment(AppStore.self) private var store
    var scope: McpToolScope

    @State private var expanded: Set<AgentToolGroup> = [.files]

    private var tools: [AgentToolDefinition] {
        store.knownToolDefinitions.filter { $0.kind != .mcp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AgentToolGroup.allCases) { group in
                let items = tools.filter { AgentToolGroup.group(for: $0) == group }
                if !items.isEmpty {
                    groupBlock(group, items: items)
                }
            }
        }
    }

    private func groupBlock(_ group: AgentToolGroup, items: [AgentToolDefinition]) -> some View {
        let isOpen = expanded.contains(group)
        let onCount = items.filter { isEnabled($0) }.count
        let allOn = !items.isEmpty && onCount == items.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if isOpen { expanded.remove(group) } else { expanded.insert(group) }
                } label: {
                    HStack {
                        Text(group.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                        Text("\(onCount)/\(items.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textGhost)
                        Spacer()
                        Text(isOpen ? "▾" : "▸")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityHint(isOpen ? "Collapse" : "Expand")

                Button {
                    toggleGroup(items, enable: !allOn)
                } label: {
                    CapsuleSwitch(isOn: allOn)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title) tools")
                .accessibilityValue(allOn ? "On" : "Off")
                .help(allOn ? "Turn off every tool in \(group.title)" : "Turn on every tool in \(group.title)")
            }
            if isOpen {
                ForEach(items) { tool in
                    ToolCapsuleToggle(
                        title: tool.label,
                        subtitle: tool.subtitle,
                        badge: tool.kind == .custom ? "custom" : nil,
                        isOn: isEnabled(tool),
                        action: { toggle(tool) }
                    )
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func isEnabled(_ tool: AgentToolDefinition) -> Bool {
        switch scope {
        case .appDefaults:
            return store.appConfig.defaultEnabledTools.contains(tool.id)
        case .bot(let botId):
            return store.bots.first(where: { $0.id == botId })?.isToolEnabled(tool.id) == true
        }
    }

    private func toggle(_ tool: AgentToolDefinition) {
        let next = !isEnabled(tool)
        switch scope {
        case .appDefaults:
            store.setDefaultTool(tool.id, enabled: next)
        case .bot(let botId):
            store.setBotTool(botId, toolId: tool.id, enabled: next)
        }
    }

    private func toggleGroup(_ items: [AgentToolDefinition], enable: Bool) {
        let ids = items.map(\.id)
        switch scope {
        case .appDefaults:
            store.setDefaultTools(ids, enabled: enable)
        case .bot(let botId):
            for id in ids {
                store.setBotTool(botId, toolId: id, enabled: enable)
            }
        }
    }
}
