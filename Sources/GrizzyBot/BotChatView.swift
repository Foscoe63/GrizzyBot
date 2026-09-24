import GrizzyBotCore
import SwiftUI

/// Every `message_bot` handoff between bots, newest last, with the answer that came back.
struct BotChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bot Chat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                if !store.botChat.isEmpty {
                    Button("Clear") { store.clearBotChat() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if store.botChat.isEmpty {
                Spacer()
                Text("When one bot hands work to another, the exchange shows up here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(40)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(store.botChat) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    .grizzyScroll()
                    .onAppear { scrollToEnd(proxy) }
                    .onChange(of: store.botChat.count) { _, _ in scrollToEnd(proxy) }
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = store.botChat.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func row(_ entry: BotChatEntry) -> some View {
        let from = store.bots.first(where: { $0.id == entry.fromBotId })
        let to = store.bots.first(where: { $0.id == entry.toBotId })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let from { BotAvatarView(bot: from, size: 18) }
                Text(from?.name ?? "Deleted bot")
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                if let to { BotAvatarView(bot: to, size: 18) }
                Text(to?.name ?? "Deleted bot")
                Spacer()
                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.textBright)

            bubble(entry.text, fill: Theme.bgCard)

            if let reply = entry.reply {
                HStack(spacing: 6) {
                    if let to { BotAvatarView(bot: to, size: 14) }
                    Text("\(to?.name ?? "Bot") replied")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                }
                bubble(reply, fill: Theme.bgHoverRow)
            } else if let note = status(entry.outcome) {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.orange)
            }
        }
    }

    private func bubble(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textBright)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func status(_ outcome: BotChatEntry.Outcome) -> String? {
        switch outcome {
        case .sent: return "Working on it — no answer yet."
        case .answered: return nil
        case .needsUser: return "Stopped and needs you to answer in its own chat."
        case .failed: return "Did not finish."
        }
    }
}
