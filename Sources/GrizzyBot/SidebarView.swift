import GrizzyBotCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var userMenuOpen = false
    @State private var showUsage = false
    @State private var hoverPlus = false
    @State private var hoverPlugins = false

    private var filteredBots: [Bot] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.bots }
        return store.bots.filter { bot in
            let preview = store.sidebarPreview(for: bot).lowercased()
            return bot.name.lowercased().contains(q) || preview.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TrafficLightSpacer()
                Spacer()
                Button {
                    store.openPanel(.create)
                } label: {
                    Text("+")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(hoverPlus ? Theme.textSidebarIconHover : Theme.textSidebarIcon)
                }
                .buttonStyle(.plain)
                .help("New bot")
                .onHover { hoverPlus = $0 }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Text("⌕")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
                TextField("Search", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.bgSearch)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.borderSearch, lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredBots) { bot in
                        botRow(bot)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .grizzyScroll()
            .frame(maxHeight: .infinity)

            pluginsButton
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            userRow
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.borderSidebar).frame(width: 1)
        }
    }

    private func botRow(_ bot: Bot) -> some View {
        let active = store.activeBotId == bot.id
        let status = store.sidebarStatus(for: bot)
        let preview = store.sidebarPreview(for: bot)
        return Button {
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                BotAvatarView(color: bot.color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bot.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if status != "idle" {
                            Text(status)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    Text(preview.isEmpty ? bot.title : preview)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(active ? Theme.bgHoverRow : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pluginsButton: some View {
        Button {
            store.pluginsOpen = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#17171A"))
                        .frame(width: 30, height: 30)
                    PuzzleIcon()
                        .stroke(Theme.textLetter, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 15, height: 15)
                }
                Text("Plugins")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textGhost)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hoverPlugins ? Color(hex: "#131315") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverPlugins = $0 }
    }

    private var userRow: some View {
        ZStack(alignment: .bottom) {
            if userMenuOpen {
                userMenu
                    .offset(y: -56)
                    .zIndex(5)
            }
            Button {
                userMenuOpen.toggle()
                if !userMenuOpen { showUsage = false }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Theme.bgUserAvatar)
                            .frame(width: 32, height: 32)
                        Text(store.session?.initials ?? "?")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSub)
                    }
                    Text(store.session?.name ?? "User")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var userMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showUsage = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("◔")
                            .foregroundStyle(Theme.textLetter)
                        Text("Weekly usage")
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.textBright)
                        Spacer()
                    }
                    if showUsage {
                        let summary = store.weeklySummary()
                        let tokens = summary.inputTokens + summary.outputTokens
                        Text("\(summary.runs) runs · \(tokens) tokens")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 24)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                userMenuOpen = false
                store.signOut()
            } label: {
                HStack(spacing: 10) {
                    Text("⇤")
                        .foregroundStyle(Theme.textLetter)
                    Text("Log out")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.textBright)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Theme.bgUserMenu)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.borderUserMenu, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 22, y: 8)
        .padding(.horizontal, -6)
    }
}

/// Puzzle piece path from HANDOFF §8 (24×24 viewBox, drawn in unit space).
struct PuzzleIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        // Approximate M4 7h3a1 1 0 0 0 1-1 1.5 1.5 0 1 1 3 0 1 1 0 0 0 1 1h3v3a1 1 0 0 0 1 1 1.5 1.5 0 1 1 0 3 1 1 0 0 0-1 1v3h-3a1 1 0 0 0-1 1 1.5 1.5 0 1 1-3 0 1 1 0 0 0-1-1H4v-3a1 1 0 0 0-1-1 1.5 1.5 0 1 1 0-3 1 1 0 0 0 1-1z
        path.move(to: p(4, 7))
        path.addLine(to: p(7, 7))
        path.addQuadCurve(to: p(8, 6), control: p(8, 7))
        path.addCurve(to: p(11, 6), control1: p(8, 4.5), control2: p(11, 4.5))
        path.addQuadCurve(to: p(12, 7), control: p(12, 6))
        path.addLine(to: p(15, 7))
        path.addLine(to: p(15, 10))
        path.addQuadCurve(to: p(16, 11), control: p(15, 11))
        path.addCurve(to: p(16, 14), control1: p(17.5, 11), control2: p(17.5, 14))
        path.addQuadCurve(to: p(15, 15), control: p(16, 15))
        path.addLine(to: p(15, 18))
        path.addLine(to: p(12, 18))
        path.addQuadCurve(to: p(11, 19), control: p(11, 18))
        path.addCurve(to: p(8, 19), control1: p(11, 20.5), control2: p(8, 20.5))
        path.addQuadCurve(to: p(7, 18), control: p(7, 19))
        path.addLine(to: p(4, 18))
        path.addLine(to: p(4, 15))
        path.addQuadCurve(to: p(3, 14), control: p(3, 15))
        path.addCurve(to: p(3, 11), control1: p(1.5, 14), control2: p(1.5, 11))
        path.addQuadCurve(to: p(4, 10), control: p(3, 10))
        path.addLine(to: p(4, 7))
        path.closeSubpath()
        return path
    }
}
