import AppKit
import GrizzyBotCore
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var hoverComputer = false

    private var bot: Bot? { store.activeBot }

    var body: some View {
        VStack(spacing: 0) {
            header
            messages
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            if let bot {
                Button {
                    store.openPanel(.settings)
                } label: {
                    HStack(spacing: 10) {
                        BotAvatarView(color: bot.color, size: 26)
                        Text(bot.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                store.toggleComputerPanel()
            } label: {
                MonitorIcon()
                    .stroke(Theme.textSub, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                    .frame(width: 30, height: 34)
                    .background(
                        store.panel == .computer ? Color(hex: "#1B1B1E") : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hoverComputer = $0 }
            .opacity(hoverComputer || store.panel == .computer ? 1 : 0.9)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if let bot {
                        ForEach(store.messages(for: bot.id)) { message in
                            MessageView(message: message, botId: bot.id)
                                .id(message.id)
                        }
                        if store.isRunActive(botId: bot.id) {
                            Text("working…")
                                .font(.system(size: 14.5))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 13)
                                .background(Theme.bgBubble)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .grizzyPulse()
                                .id("working-pulse")
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .grizzyScroll()
            .onChange(of: bot.map { store.messages(for: $0.id).count } ?? 0) { _, _ in
                if let last = bot.flatMap({ store.messages(for: $0.id).last }) {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 14) {
            Text("+")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textLetter)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle().stroke(Theme.borderInputsDark, lineWidth: 1)
                }

            TextField(
                bot.map { "Message \($0.name)" } ?? "Message",
                text: $draft,
                axis: .vertical
            )
            .font(.system(size: 15.5))
            .foregroundStyle(Theme.textInput)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .onSubmit {
                if NSEvent.modifierFlags.contains(.shift) {
                    draft += "\n"
                } else {
                    send()
                }
            }

            Button {
                if let bot, store.isRunActive(botId: bot.id) {
                    store.stopRun(botId: bot.id)
                } else {
                    send()
                }
            } label: {
                Text(bot.map { store.isRunActive(botId: $0.id) } == true ? "■" : "↑")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textCream)
                    .frame(width: 36, height: 36)
                    .background(Theme.bgCream)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(Theme.bgInputBar)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Theme.borderSearch, lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func send() {
        guard let bot else { return }
        let text = draft
        draft = ""
        store.send(botId: bot.id, text: text)
    }
}

private struct MonitorIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        // rect x2 y4 w20 h13 rx2
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 2 * sx, y: rect.minY + 4 * sy, width: 20 * sx, height: 13 * sy),
            cornerSize: CGSize(width: 2 * sx, height: 2 * sy)
        )
        // stand
        path.move(to: p(9, 17))
        path.addLine(to: p(9, 20))
        path.addLine(to: p(15, 20))
        path.addLine(to: p(15, 17))
        path.move(to: p(7, 20))
        path.addLine(to: p(17, 20))
        return path
    }
}
