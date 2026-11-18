import GrizzyBotCore
import SwiftUI

/// Settings → a bot → Tool selection. Cuts the tool list a model is shown, for small-context local models.
struct ToolSelectionSection: View {
    @Environment(AppStore.self) private var store
    let bot: Bot

    @State private var allowOnly = false
    @State private var lean = false
    @State private var allowText = ""
    @State private var excludeText = ""
    @State private var loadedFor: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tool selection")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 16)
            Toggle("Only offer listed tools", isOn: $allowOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .padding(.top, 8)
            if allowOnly {
                selectorField("Allow", text: $allowText)
            }
            selectorField("Exclude", text: $excludeText)
            Toggle("Lean turns — send only the tools each message needs", isOn: $lean)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .padding(.top, 8)
            HStack {
                Button("Save tool selection") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.top, 10)
            Text("One selector per line: a built-in tool (read_file), builtin:*, mcp:*, mcp:server:* or mcp:server:tool. Exclude always wins, and an empty allow list means no tools. Lean turns keep the few tools a message looks like it needs; the rest stay one capabilities_load away. The loop's own tools (todo, complete, clarify, capabilities_*) are always on. Takes effect on the next turn.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 6)
        }
        .onAppear(perform: load)
        .onChange(of: bot.id) { _, _ in load() }
    }

    private func selectorField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            GrizzyTextEditor(placeholder: "one selector per line", text: text, fontSize: 12.5, textColor: Theme.textCream, lines: 3...4)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textMuted.opacity(0.3)))
        }
        .padding(.top, 8)
    }

    private func load() {
        guard loadedFor != bot.id else { return }
        loadedFor = bot.id
        let selection = bot.toolSelection ?? ToolSelection()
        allowOnly = selection.allowOnly
        lean = selection.lean
        allowText = selection.allow.joined(separator: "\n")
        excludeText = selection.exclude.joined(separator: "\n")
        message = nil
    }

    private func save() {
        let allow = ToolSelection.parseLines(allowText)
        let exclude = ToolSelection.parseLines(excludeText)
        let invalid = allow.invalid + exclude.invalid
        guard invalid.isEmpty else {
            message = "Can't read: \(invalid.prefix(3).joined(separator: ", "))"
            return
        }
        let selection = ToolSelection(allowOnly: allowOnly, allow: allow.selectors, exclude: exclude.selectors, lean: lean)
        store.setBotToolSelection(bot.id, selection)
        let unknown = selection.unknownSelectors(knownMcpServers: store.toolSelectionServerNames)
        message = unknown.isEmpty ? "Saved." : "Saved. Nothing matches: \(unknown.prefix(3).joined(separator: ", "))"
    }
}
