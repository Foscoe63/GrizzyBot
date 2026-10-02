import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

extension AppSettingsOverlayView {
    @ViewBuilder
    var toolsSection: some View {
        settingsCard(
            title: "MCP servers",
            subtitle: "Green means the server answered tools/list. Red means it did not. Expand a server to turn individual tools on or off for new bots."
        ) {
            McpServersToolsBlock(
                scope: .appDefaults,
                showsEditor: true,
                editingId: editingMcpId,
                onEdit: { beginEdit($0) },
                onDelete: { server in
                    if editingMcpId == server.id { clearMcpForm() }
                    store.deleteMcpServer(server.id)
                }
            )

            Divider()
                .overlay(Theme.borderListRowsAlt)
                .padding(.vertical, 8)

            Button {
                if editingMcpId != nil {
                    clearMcpForm()
                } else {
                    addMcpOpen.toggle()
                }
            } label: {
                HStack {
                    Text(editingMcpId == nil ? "Add MCP server" : "Editing \(mcpName.isEmpty ? "server" : mcpName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Spacer()
                    Text(addMcpOpen || editingMcpId != nil ? "▾" : "▸")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if addMcpOpen || editingMcpId != nil {
                mcpEditorForm
                    .padding(.top, 10)
            }
        }

        settingsCard(
            title: "Default tools for new bots",
            subtitle: "Applied when you create a bot. Existing bots keep their own Tools list. MCP servers are configured above."
        ) {
            HStack(spacing: 12) {
                Button("Enable all") {
                    store.setAllDefaultTools(enabled: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSidebarIcon)

                Button("Disable all") {
                    store.setAllDefaultTools(enabled: false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.orange)
            }
            .padding(.bottom, 4)

            GroupedBuiltinToolsList(scope: .appDefaults)
        }
    }

    var tokenCountersBody: some View {
        let botId = store.activeBotId
        let bot = store.bots.first(where: { $0.id == botId })
        let stats = store.chatTokenStats(botId: botId ?? "")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text(bot?.name ?? "No bot selected")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                tokenCounterStat(label: "Prompt", value: stats.lastPromptTokens)
                tokenCounterStat(label: "Sent", value: stats.sentTokens)
                tokenCounterStat(label: "Recv", value: stats.receivedTokens)
            }
            HStack(spacing: 12) {
                GrizzyButton(
                    title: "Reset this bot",
                    variant: .cream,
                    size: .sm,
                    disabled: botId == nil
                ) {
                    if let botId {
                        store.resetChatTokens(botId: botId)
                    }
                }
                GrizzyButton(
                    title: "Reset all bots",
                    variant: .outline,
                    size: .sm
                ) {
                    confirmResetAllTokens = true
                }
            }
        }
    }

    func tokenCounterStat(label: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Text(TokenAccounting.grouped(value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
