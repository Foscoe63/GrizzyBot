import AppKit
import GrizzyBotCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var userMenuOpen = false
    @State private var showUsage = false
    @State private var hoverPlus = false
    @State private var hoverPlugins = false
    @State private var hoverSkills = false
    @State private var showNewMenu = false
    @State private var showCreateRoom = false
    @State private var roomName = ""
    @State private var roomMemberIds: Set<String> = []

    private var filteredBots: [Bot] {
        let base = store.visibleBots
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { bot in
            let preview = store.sidebarPreview(for: bot).lowercased()
            return bot.name.lowercased().contains(q) || preview.contains(q)
        }
    }

    private var filteredGroups: [GroupRoom] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.groups }
        return store.groups.filter {
            $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TrafficLightSpacer()
                Spacer()
                Button {
                    showNewMenu.toggle()
                } label: {
                    Text("+")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(hoverPlus ? Theme.textSidebarIconHover : Theme.textSidebarIcon)
                }
                .buttonStyle(.plain)
                .help("New bot or room")
                .onHover { hoverPlus = $0 }
                .popover(isPresented: $showNewMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            showNewMenu = false
                            store.openPanel(.create)
                        } label: {
                            Label("New bot", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showNewMenu = false
                            roomName = ""
                            roomMemberIds = Set(store.visibleBots.prefix(2).map(\.id))
                            showCreateRoom = true
                        } label: {
                            Label("New room", systemImage: "person.2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.visibleBots.count < 2)
                    }
                    .frame(width: 180)
                    .padding(6)
                    .background(Theme.bgUserMenu)
                }
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
                    if !filteredGroups.isEmpty {
                        sectionLabel("Rooms")
                        ForEach(filteredGroups) { group in
                            groupRow(group)
                        }
                        sectionLabel("Bots")
                            .padding(.top, 8)
                    }

                    ForEach(filteredBots) { bot in
                        botRow(bot)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .grizzyScroll()
            .frame(maxHeight: .infinity)

            routinesButton
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            pluginsButton
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            skillsButton
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
        .sheet(isPresented: $showCreateRoom) {
            createRoomSheet
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func botRow(_ bot: Bot) -> some View {
        let active = store.mainView == .chat && store.activeBotId == bot.id && store.activeGroupId == nil
        let status = store.sidebarStatus(for: bot)
        let preview = store.sidebarPreview(for: bot)
        return Button {
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                BotAvatarView(color: bot.color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        if bot.pinned {
                            Text("⌖")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Text(bot.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if bot.unread {
                            Circle()
                                .fill(Theme.orange)
                                .frame(width: 7, height: 7)
                        } else if status != "idle" {
                            Text(status)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    HStack(spacing: 6) {
                        if bot.chiefOfStaff {
                            Text("Chief of Staff")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.orange)
                        }
                        Text(preview.isEmpty ? bot.title : preview)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                active
                    ? Theme.orange.opacity(0.16)
                    : (bot.chiefOfStaff ? Theme.orange.opacity(0.07) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if active || bot.chiefOfStaff {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.orange.opacity(active ? 0.45 : 0.25), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(bot.pinned ? "Unpin" : "Pin") {
                store.setBotPinned(bot.id, pinned: !bot.pinned)
            }
            Button(bot.chiefOfStaff ? "Remove Chief of Staff" : "Make Chief of Staff") {
                store.setChiefOfStaff(bot.id, enabled: !bot.chiefOfStaff)
            }
            Button("Mark as Unread") {
                store.markBotUnread(bot.id)
            }
            Divider()
            Button("Edit Profile") {
                store.selectBot(bot.id)
                store.openPanel(.settings)
            }
            Button("Duplicate") {
                _ = store.duplicateBot(bot.id)
            }
            Divider()
            Button("Copy conversation ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bot.threadId, forType: .string)
            }
            Divider()
            Button("Hide from sidebar") {
                store.setBotHidden(bot.id, hidden: true)
            }
            .disabled(bot.chiefOfStaff)
            Button("Delete", role: .destructive) {
                store.deleteBot(bot.id)
            }
        }
    }

    private func groupRow(_ group: GroupRoom) -> some View {
        let active = store.activeGroupId == group.id
        return Button {
            store.selectGroup(group.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.bgLetterBadge)
                        .frame(width: 38, height: 38)
                    Text("◇")
                        .foregroundStyle(Theme.textLetter)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(group.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textBright)
                            .lineLimit(1)
                        Spacer()
                        if group.unread {
                            Circle().fill(Theme.orange).frame(width: 7, height: 7)
                        }
                    }
                    Text(group.preview.isEmpty ? "\(group.memberIds.count) members" : group.preview)
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
        .contextMenu {
            Button("Delete room", role: .destructive) {
                store.deleteGroup(group.id)
            }
        }
    }

    private var routinesButton: some View {
        Button {
            store.showRoutinesPage()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.bgCard)
                        .frame(width: 30, height: 30)
                    Text("◷")
                        .font(.system(size: 13))
                        .foregroundStyle(store.mainView == .routines ? Theme.orange : Theme.textLetter)
                }
                Text("Routines")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textGhost)
                Spacer()
                if store.missedRoutineCount > 0 {
                    Text("\(store.missedRoutineCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(store.mainView == .routines ? Theme.bgHoverRow : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pluginsButton: some View {
        Button {
            store.openPlugins()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.bgCard)
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
            .background(hoverPlugins ? Theme.bgHoverRow : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverPlugins = $0 }
    }

    private var skillsButton: some View {
        Button {
            store.skillsOpen = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.bgCard)
                        .frame(width: 30, height: 30)
                    Text("✦")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textLetter)
                }
                Text("Skills")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.textGhost)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hoverSkills ? Theme.bgHoverRow : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverSkills = $0 }
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
                store.openModelSettings()
            } label: {
                menuRow(icon: "◈", title: "Model")
            }
            .buttonStyle(.plain)

            Button {
                userMenuOpen = false
                store.openAppSettings()
            } label: {
                menuRow(icon: "⚙", title: "Settings")
            }
            .buttonStyle(.plain)

            Button {
                userMenuOpen = false
                store.signOut()
            } label: {
                menuRow(icon: "⇤", title: "Log out")
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

    private func menuRow(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Text(icon)
                .foregroundStyle(Theme.textLetter)
            Text(title)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textBright)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var createRoomSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New room")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            GrizzyField(label: "Name", placeholder: "Room name", text: $roomName)
            Text("Members")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            ForEach(store.visibleBots) { bot in
                Toggle(isOn: Binding(
                    get: { roomMemberIds.contains(bot.id) },
                    set: { on in
                        if on { roomMemberIds.insert(bot.id) }
                        else { roomMemberIds.remove(bot.id) }
                    }
                )) {
                    Text(bot.name)
                        .foregroundStyle(Theme.textBright)
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCreateRoom = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Button("Create") {
                    let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    _ = store.createGroup(name: name, memberIds: Array(roomMemberIds))
                    showCreateRoom = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textCream)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.bgCream)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty || roomMemberIds.count < 2)
                .opacity(roomName.trimmingCharacters(in: .whitespaces).isEmpty || roomMemberIds.count < 2 ? 0.45 : 1)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Theme.bgRightPanel)
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
