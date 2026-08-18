import AppKit
import GrizzyBotCore
import SwiftUI

struct MessageView: View {
    let message: ThreadMessage
    let botId: String
    @Environment(AppStore.self) private var store

    private let reactionEmojis = ["👍", "👀", "✅", "🔥"]
    @State private var copied = false
    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                if message.role == .user {
                    Spacer(minLength: 48)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .contextMenu {
                    Button("Copy") { copyMessage() }
                    if message.role == .user {
                        Button("Edit & resend") {
                            editText = message.firstText
                            editing = true
                        }
                        Button("Branch from here") {
                            _ = store.branchFromMessage(botId: botId, messageId: message.id)
                        }
                        Button("Regenerate") {
                            store.regenerateFrom(botId: botId, messageId: message.id)
                        }
                    }
                    if message.role == .bot {
                        Menu("React") {
                            ForEach(reactionEmojis, id: \.self) { emoji in
                                Button(emoji) {
                                    store.toggleReaction(botId: botId, messageId: message.id, emoji: emoji)
                                }
                            }
                        }
                        Button("Regenerate") {
                            store.regenerateFrom(botId: botId, messageId: message.id)
                        }
                        Button("Branch from here") {
                            _ = store.branchFromMessage(botId: botId, messageId: message.id)
                        }
                        Button("Speak") {
                            ReplySpeaker.speak(
                                message.firstText,
                                voiceName: store.appConfig.ttsVoice,
                                apiKey: store.appConfig.ttsKey
                            )
                        }
                    }
                }

                if canCopy {
                    copyButton
                }
                if message.role != .user {
                    Spacer(minLength: 48)
                }
            }

            if !message.reactions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.reactions) { reaction in
                        Button {
                            store.toggleReaction(botId: botId, messageId: message.id, emoji: reaction.emoji)
                        } label: {
                            Text("\(reaction.emoji) \(reaction.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.bgCard)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .meta(let text):
            HStack(spacing: 8) {
                Text("◷")
                    .foregroundStyle(Theme.orange)
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

        case .progress(let text):
            let visible = StreamText.visible(text)
            MarkdownText(source: visible.isEmpty ? "thinking…" : visible, streaming: true, textColor: Theme.textPrimary, fontSize: 15.5)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Theme.bgBubble)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: bubbleMax(0.74), alignment: .leading)

        case .subagent(_, let name, let task, let status, let progress, let result):
            subagentCard(name: name, task: task, status: status, progress: progress, result: result)

        case .childBot(let childId, let name, let title, let status):
            childBotCard(botId: childId, name: name, title: title, status: status)

        case .text(let text):
            if message.role == .user {
                if editing {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("Edit message", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15.5))
                            .foregroundStyle(Theme.textUserBubble)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Theme.bgCream)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        HStack {
                            Button("Cancel") { editing = false }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                            Button("Save & run") {
                                store.editUserMessage(botId: botId, messageId: message.id, text: editText)
                                editing = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textCream)
                        }
                    }
                    .frame(maxWidth: bubbleMax(0.70), alignment: .trailing)
                } else {
                    Text(text)
                        .font(.system(size: 15.5))
                        .foregroundStyle(Theme.textUserBubble)
                        .lineSpacing(15.5 * 0.45)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .frame(maxWidth: bubbleMax(0.70), alignment: .trailing)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    MarkdownText(source: text, textColor: Theme.textPrimary, fontSize: 15.5)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Theme.bgBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Button {
                        ReplySpeaker.speak(text, voiceName: store.appConfig.ttsVoice, apiKey: store.appConfig.ttsKey)
                    } label: {
                        Text("♪")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textLetter)
                    }
                    .buttonStyle(.plain)
                    .help("Speak this reply")
                }
                .frame(maxWidth: bubbleMax(0.74), alignment: .leading)
            }

        case .card(let lines):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("✓")
                            .foregroundStyle(Theme.greenAlt)
                        Text(line.k)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("→")
                            .foregroundStyle(Theme.textSecondary)
                        Text(line.v)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Theme.bgBubble)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: bubbleMax(0.74), alignment: .leading)

        case .ask(let text, let detail):
            askCard(text: text, detail: detail)

        case .computer(let state, let text):
            computerCard(state: state, text: text)

        case .choice(let question, let subtitle, let options):
            choiceCard(question: question, subtitle: subtitle, options: options)

        case .connect(let name, let initial, let color, let status):
            connectCard(name: name, initial: initial, color: color, status: status)

        case .approval(let tool, let detail, let status):
            approvalCard(tool: tool, detail: detail, status: status)
        }
    }

    private func bubbleMax(_ fraction: CGFloat) -> CGFloat {
        900 * fraction
    }

    private var copyableText: String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .ask(let t, _): return t
            case .progress(let t): return StreamText.visible(t)
            case .computer(_, let t): return t
            case .choice(let q, _, _): return q
            case .approval(let tool, let detail, _): return "\(tool)\n\(detail)"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    private var canCopy: Bool {
        !copyableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var copyButton: some View {
        Button {
            copyMessage()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Theme.green : Theme.textLetter)
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel("Copy")
    }

    private func copyMessage() {
        let text = copyableText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func choiceCard(question: String, subtitle: String?, options: [ChoiceOption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(Theme.textBright)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 8) {
                ForEach(options, id: \.id) { option in
                    Button {
                        store.answerChoice(botId: botId, messageId: message.id, option: option)
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.letter)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textCream)
                                .frame(width: 24, height: 24)
                                .background(Theme.bgCream.opacity(0.2))
                                .clipShape(Circle())
                            Text(option.label)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Theme.textBright)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: bubbleMax(0.74), alignment: .leading)
        .background(Theme.bgAsk)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.borderAsk, lineWidth: 1)
        }
    }

    private func approvalCard(tool: String, detail: String, status: ApprovalStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Approval needed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                Text(statusLabel(status))
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor(status))
            }
            Text(tool)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.orange)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgCode)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if status == .pending {
                HStack(spacing: 8) {
                    approvalButton("Allow", decision: .allow)
                    approvalButton("Always allow", decision: .alwaysAllow)
                    approvalButton("Deny", decision: .deny, danger: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: bubbleMax(0.74), alignment: .leading)
        .background(Theme.bgAsk)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.borderAsk, lineWidth: 1)
        }
    }

    private func approvalButton(_ title: String, decision: ApprovalDecision, danger: Bool = false) -> some View {
        Button {
            store.answerApproval(botId: botId, messageId: message.id, decision: decision)
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(danger ? Theme.orange : Theme.textCream)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(danger ? Theme.bgDeleteConfirm : Theme.bgCream)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if danger {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.borderDelete, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func statusLabel(_ status: ApprovalStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .allowed: return "allowed"
        case .denied: return "denied"
        case .alwaysAllowed: return "always"
        }
    }

    private func statusColor(_ status: ApprovalStatus) -> Color {
        switch status {
        case .pending: return Theme.amber
        case .allowed, .alwaysAllowed: return Theme.green
        case .denied: return Theme.orange
        }
    }

    private func connectCard(name: String, initial: String, color: String, status: ConnectStatus) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: color)).frame(width: 36, height: 36)
                Text(initial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Text(status == .connected ? "Connected" : "Connect to continue")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: bubbleMax(0.6), alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func subagentCard(
        name: String,
        task: String,
        status: SubagentStatus,
        progress: String?,
        result: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                statusPill(status)
            }
            Text(task)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            if let body = result ?? progress, !body.isEmpty {
                MarkdownText(
                    source: body,
                    streaming: status == .running,
                    textColor: Theme.textSub,
                    fontSize: 14.5
                )
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: min(420, 900 * 0.9), alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
        }
    }

    private func statusPill(_ status: SubagentStatus) -> some View {
        let label: String
        let color: Color
        let bg: Color
        switch status {
        case .running:
            label = "subagent"
            color = Theme.amber
            bg = Color(hex: "#F5A03C").opacity(0.14)
        case .completed:
            label = "completed"
            color = Theme.green
            bg = Color(hex: "#30A24B").opacity(0.14)
        case .failed:
            label = "failed"
            color = Theme.orange
            bg = Color(hex: "#E65707").opacity(0.14)
        }
        return Text(label)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
            .modifier(ConditionalPulse(active: status == .running))
    }

    private func childBotCard(
        botId: String,
        name: String,
        title: String?,
        status: ChildBotStatus
    ) -> some View {
        let deleted = status == .deleted
        return Button {
            guard !deleted else { return }
            store.selectBot(botId)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                    Spacer()
                    Text(deleted ? "deleted" : "bot")
                        .font(.system(size: 13))
                        .foregroundStyle(deleted ? Theme.orange : Theme.green)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            (deleted ? Color(hex: "#E65707") : Color(hex: "#30A24B")).opacity(0.14)
                        )
                        .clipShape(Capsule())
                }
                Text(
                    deleted
                        ? "Removed this bot, including its chat, computer, and memory."
                        : (title?.isEmpty == false ? title! : "Opened its own thread. Tap to switch.")
                )
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textSub)
                .padding(.top, 8)
                .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: min(340, 900 * 0.9), alignment: .leading)
            .background(Theme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .opacity(deleted ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(deleted)
    }

    private func askCard(text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownText(source: text, textColor: Theme.textBright, fontSize: 15.5)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(12.5 * 0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.bgCode)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 10)
            }
            HStack(spacing: 8) {
                Button {
                    store.answerAsk(botId: botId, answer: "approved")
                } label: {
                    Text("Send it")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.textCream)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 8)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    // rakazo: no action
                } label: {
                    Text("Edit first")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textGhost)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 8)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(maxWidth: bubbleMax(0.74), alignment: .leading)
        .background(Theme.bgAsk)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.borderAsk, lineWidth: 1)
        }
    }

    private func computerCard(state: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Computer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                Text(state)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.green)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#30A24B").opacity(0.14))
                    .clipShape(Capsule())
            }
            MarkdownText(source: text, textColor: Theme.textSub, fontSize: 14.5)
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 340, alignment: .leading)
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.borderListRowsAlt, lineWidth: 1)
        }
    }
}

private struct ConditionalPulse: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.grizzyPulse()
        } else {
            content
        }
    }
}
