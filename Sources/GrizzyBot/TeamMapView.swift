import AppKit
import GrizzyBotCore
import SwiftUI

/// The Team map: every bot, grouped into department panels on a pannable, zoomable canvas, with a box
/// at the bottom to message bots, a department, or everyone.
struct TeamMapView: View {
    @Environment(AppStore.self) private var store

    @State private var view = TeamMapView_Transform()
    @State private var didFit = false
    @State private var panStart: TeamMapView_Transform?
    @State private var zoomStart: Double?
    @State private var panelDrag: (key: String, origin: CanvasPoint, offset: CGSize)?
    @State private var botDrag: (bot: Bot, location: CGPoint)?
    @State private var pendingMove: (bot: Bot, dept: String)?
    @State private var showComputers = false
    @State private var showUsage = false
    @State private var usageDays = 7
    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @State private var editingInstructions: Named?
    @State private var editingMemory: Named?
    @State private var draft = ""
    @State private var sentTo: (ids: [String], chief: String?)?
    @State private var flash: Set<String> = []
    @State private var announcement = ""
    @State private var sheetError = ""
    @State private var canvasSize = CGSize(width: 800, height: 500)

    private let space = "teamMapCanvas"

    private var sections: [TeamMapSection] { store.teamMapSections }
    private var visibleCount: Int { store.bots.filter { !$0.hidden }.count }

    /// Tiles with any in-flight panel drag applied.
    private var tiles: [TeamMapTile] {
        var positions = store.teamMap.positions
        if let d = panelDrag {
            positions[d.key] = CanvasPoint(x: d.origin.x + d.offset.width / view.scale, y: d.origin.y + d.offset.height / view.scale)
        }
        return TeamMapLogic.layout(sections, positions: positions)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.borderMainHdr).frame(height: 1)
            ZStack(alignment: .bottom) {
                canvas
                composer.padding(.bottom, 20).padding(.horizontal, 16)
            }
        }
        .background(Theme.bgMain)
        .sheet(isPresented: $creating) { departmentSheet(title: "New department", text: $newName, confirm: "Create") {
            if store.createDepartment(newName) { creating = false } else { sheetError = "That name is taken or empty." }
        } }
        .sheet(item: Binding(get: { renaming.map { Named(name: $0) } }, set: { renaming = $0?.name })) { item in
            departmentSheet(title: "Rename \(item.name)", text: $renameText, confirm: "Save") {
                if store.renameDepartment(item.name, to: renameText) { renaming = nil } else { sheetError = "That name is taken or empty." }
            }
        }
        .sheet(item: $editingMemory) { item in
            DepartmentMemorySheet(department: item.name) { editingMemory = nil }
        }
        .sheet(item: $editingInstructions) { item in
            DepartmentInstructionsSheet(department: item.name) { editingInstructions = nil }
        }
        .confirmationDialog(pendingMove.map { "Move \($0.bot.name) to \($0.dept.isEmpty ? "General" : $0.dept)?" } ?? "",
                            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible) {
            Button("Move") { if let m = pendingMove { store.moveBot(m.bot.id, toDepartment: m.dept); announcement = "Moved \(m.bot.name)." }; pendingMove = nil }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { Text("The bot keeps its memory and chats; only the department changes.") }
        .confirmationDialog(deleting.map { "Delete \($0)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete department", role: .destructive) { if let d = deleting { store.deleteDepartment(d) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its bots are kept and move to General.") }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "person.3").foregroundStyle(Theme.textSecondary)
                    Text("Team map").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textBright)
                    Text(TeamMapLogic.botCountLabel(visibleCount)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Text("Your bots, their departments, and how they work together.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { store.teamMap.showScreens }, set: { store.setShowScreens($0) })) {
                Text("Show screens").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch).controlSize(.small)
            .help("Show each bot's computer on its card")
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(store.teamMap.showScreens ? Theme.bgHoverRow : Theme.bgCard))
            Button { showComputers.toggle() } label: { Image(systemName: "display").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).padding(8)
                .accessibilityLabel("Computers")
                .popover(isPresented: $showComputers, arrowEdge: .bottom) { computersList }
            Button { showUsage.toggle() } label: { Image(systemName: "chart.bar").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).padding(8)
                .accessibilityLabel("Usage by department")
                .popover(isPresented: $showUsage, arrowEdge: .bottom) { usageList }
            Menu {
                Button("New department") { newName = ""; sheetError = ""; creating = true }
            } label: {
                Label("Add", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).stroke(Theme.borderInputsDark))
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var usageList: some View {
        let rows = store.departmentUsage(days: usageDays)
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage by department").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $usageDays) {
                    Text("7 days").tag(7); Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.name).foregroundStyle(row.filed ? Theme.textBright : Theme.textMuted).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(row.runs) run\(row.runs == 1 ? "" : "s") · \(TokenAccounting.grouped(row.tokens)) tokens")
                            .foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 12))
                    GeometryReader { g in
                        Capsule().fill(Theme.orange.opacity(0.7)).frame(width: max(row.tokens == 0 ? 0 : 3, g.size.width * CGFloat(row.tokens) / CGFloat(total)))
                    }.frame(height: 4)
                }
            }
            Text("Counted in the department a bot was in when it ran, so moving a bot never rewrites its past.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 400)
    }

    private var computersList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computers").font(.system(size: 13, weight: .semibold))
            let withComputer = store.bots.filter { !$0.hidden && $0.computerMode != .off }
            if withComputer.isEmpty {
                Text("No bot has a computer turned on.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            ForEach(withComputer) { bot in
                Button { showComputers = false; openComputer(bot) } label: {
                    HStack { Text(bot.name); Spacer(); Text(computerState(bot)).foregroundStyle(Theme.textMuted) }
                        .font(.system(size: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(14).frame(width: 260)
    }

    private func computerState(_ bot: Bot) -> String {
        store.computers[bot.id]?.state == .running ? "Running" : "Off"
    }

    private func openComputer(_ bot: Bot) {
        store.activeBotId = bot.id
        store.openComputerOverlay()
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dotGrid
                ZStack(alignment: .topLeading) {
                    ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                        let tile = tiles[index]
                        panel(section, tile: tile)
                        ForEach(section.chiefs + section.members) { bot in
                            if let o = TeamMapLogic.cardOrigins(section, in: tile)[bot.id] {
                                card(bot)
                                    .offset(x: o.x, y: o.y)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No bots yet.").foregroundStyle(Theme.textMuted).offset(x: 40, y: 40)
                    }
                }
                .frame(width: 1, height: 1, alignment: .topLeading)
                .scaleEffect(view.scale, anchor: .topLeading)
                .offset(x: view.x, y: view.y)

                if let d = botDrag {
                    HStack(spacing: 8) { BotAvatarView(bot: d.bot, size: 24); Text(d.bot.name).font(.system(size: 13)) }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgCard))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.orange.opacity(0.5)))
                        .offset(x: d.location.x + 14, y: d.location.y + 14)
                        .allowsHitTesting(false)
                }
                zoomControls(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                let start = panStart ?? view
                panStart = start
                view.x = start.x + g.translation.width
                view.y = start.y + g.translation.height
            }.onEnded { _ in panStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { g in
                let base = zoomStart ?? view.scale
                zoomStart = base
                setScale(base * g.magnification, around: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
            }.onEnded { _ in zoomStart = nil })
            .background(ScrollWheelCatcher { dx, dy, zoom, point in
                if zoom { setScale(view.scale * exp(-dy * 0.006), around: point) }
                else { view.x += dx; view.y += dy }
            })
            .clipped()
            .onAppear { canvasSize = geo.size; fitIfNeeded() }
            .onChange(of: geo.size) { _, new in canvasSize = new; if !didFit { fitIfNeeded() } }
            .onChange(of: tiles.map { [$0.width, $0.height] }) { _, _ in fit() }
        }
    }

    private var dotGrid: some View {
        Canvas { ctx, size in
            let step = max(8, 24 * view.scale)
            var x = view.x.truncatingRemainder(dividingBy: step)
            while x < size.width {
                var y = view.y.truncatingRemainder(dividingBy: step)
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(Theme.textMuted.opacity(0.35)))
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }

    private func zoomControls(_ size: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { setScale(view.scale / 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
            Button { fit() } label: { Text("\(Int((view.scale * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(minWidth: 40) }
                .help("Fit everything").accessibilityLabel("Fit")
            Button { setScale(view.scale * 1.2, around: CGPoint(x: size.width / 2, y: size.height / 2)) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderListRows))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(20)
    }

    // MARK: Panels and cards

    private func panel(_ section: TeamMapSection, tile: TeamMapTile) -> some View {
        let dropping = botDrag.map { d in
            let p = world(d.location)
            return TeamMapLogic.department(at: p, tiles: tiles) == section.key && store.department(of: d.bot.id) != section.key
        } ?? false
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(Theme.bgCard.opacity(0.9))
            RoundedRectangle(cornerRadius: 16).stroke(dropping ? Theme.orange : Theme.borderListRows, lineWidth: dropping ? 2 : 1)
            HStack(spacing: 8) {
                Text(section.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textBright).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: TeamMapLogic.headerHeight)
                    .contentShape(Rectangle())
                    .help("Drag to rearrange")
                    .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(space)).onChanged { g in
                        let origin = panelDrag?.origin ?? CanvasPoint(x: tile.x, y: tile.y)
                        panelDrag = (section.key, origin, g.translation)
                    }.onEnded { g in
                        if let d = panelDrag {
                            store.setDepartmentPosition(d.key, CanvasPoint(x: d.origin.x + g.translation.width / view.scale,
                                                                          y: d.origin.y + g.translation.height / view.scale))
                        }
                        panelDrag = nil
                    })
                Text("\(section.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                panelMenu(section)
            }
            .padding(.horizontal, 20)
            if section.count == 0 {
                Text("Drag a bot here")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .frame(width: TeamMapLogic.cardWidth, height: TeamMapLogic.cardHeight)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.borderListRows))
                    .offset(x: TeamMapLogic.padding, y: TeamMapLogic.headerHeight)
            }
        }
        .frame(width: tile.width, height: tile.height)
        .offset(x: tile.x, y: tile.y)
    }

    private func panelMenu(_ section: TeamMapSection) -> some View {
        Menu {
            Button("Shared instructions…") { editingInstructions = Named(name: section.key) }
            Button(store.pendingFactCount(section.key) > 0 ? "Shared memory… (\(store.pendingFactCount(section.key)) to review)" : "Shared memory…") {
                editingMemory = Named(name: section.key)
            }
            Divider()
            Button("Rename") { renameText = section.name; sheetError = ""; renaming = section.key }
                .disabled(section.key.isEmpty)
            Button("Delete department", role: .destructive) { deleting = section.key }
                .disabled(section.key.isEmpty)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    // A bot suggested a note: the person has something to review.
                    if store.pendingFactCount(section.key) > 0 {
                        Circle().fill(Theme.orange).frame(width: 7, height: 7).offset(x: -3, y: 4)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Theme.textSecondary)
        .accessibilityLabel("Manage \(section.name)")
    }

    private func card(_ bot: Bot) -> some View {
        let tagged = TeamMapLogic.targets(text: draft, bots: store.bots, state: store.teamMap).botIds.contains(bot.id)
        let selected = store.activeBotId == bot.id && store.panel == .settings
        let isDragging = botDrag?.bot.id == bot.id
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                BotAvatarView(bot: bot, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textBright).lineLimit(1)
                        if bot.chiefOfStaff { Image(systemName: "crown.fill").font(.system(size: 10)).foregroundStyle(Theme.orange).help("Chief of Staff") }
                    }
                    Text(bot.title.isEmpty ? (bot.chiefOfStaff ? "Chief of Staff" : "Bot") : bot.title)
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 82)
            .contentShape(Rectangle())
            .onTapGesture { openSettings(bot) }
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(space)).onChanged { g in
                botDrag = (bot, g.location)
            }.onEnded { g in finishBotDrag(bot, at: g.location) })
            Rectangle().fill(Theme.borderListRows).frame(height: 1)
            HStack(spacing: 4) {
                Button { store.selectBot(bot.id) } label: { Image(systemName: "bubble.left").font(.system(size: 12)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Open chat")
                    .accessibilityLabel("Open chat with \(bot.name)")
                if store.sidebarStatus(for: bot) != "idle" { statusDot }
                if store.teamMap.showScreens && bot.computerMode != .off {
                    Button { openComputer(bot) } label: { Image(systemName: "display").font(.system(size: 12)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).foregroundStyle(store.computers[bot.id]?.state == .running ? Theme.orange : Theme.textSecondary)
                        .help("Open \(bot.name)'s computer")
                }
                Spacer(minLength: 0)
                Button { openSettings(bot) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu").font(.system(size: 10))
                        Text(modelName(bot)).font(.system(size: 10)).lineLimit(1)
                    }.frame(maxWidth: 130)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Change model")
            }
            .padding(.horizontal, 8).frame(height: 43)
        }
        .frame(width: TeamMapLogic.cardWidth, height: TeamMapLogic.cardHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgMain))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tagged ? Theme.orange : selected ? Theme.orange.opacity(0.6) : Theme.borderListRows, lineWidth: tagged ? 2 : 1))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.orange, lineWidth: 2).opacity(flash.contains(bot.id) ? 1 : 0))
        .opacity(isDragging ? 0.35 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bot.name), \(bot.title)")
    }

    private var statusDot: some View {
        HStack(spacing: 5) { Circle().fill(Color.green).frame(width: 6, height: 6); Text("Working").font(.system(size: 10)) }
            .foregroundStyle(Theme.textSecondary)
    }

    private func modelName(_ bot: Bot) -> String {
        bot.modelId ?? store.modelId ?? "Default model"
    }

    private func openSettings(_ bot: Bot) {
        store.activeBotId = bot.id
        store.openPanel(.settings)
    }

    // MARK: Drag handling

    private func world(_ p: CGPoint) -> CanvasPoint {
        CanvasPoint(x: (p.x - view.x) / view.scale, y: (p.y - view.y) / view.scale)
    }

    private func finishBotDrag(_ bot: Bot, at location: CGPoint) {
        defer { botDrag = nil }
        let p = world(location)
        let current = tiles
        guard let dest = TeamMapLogic.department(at: p, tiles: current) else { return }
        if dest == store.department(of: bot.id) {
            guard let i = sections.firstIndex(where: { $0.key == dest }) else { return }
            let index = TeamMapLogic.insertionIndex(of: bot, in: sections[i], tile: current[i], y: p.y)
            store.arrangeBot(bot.id, toIndex: index)
            announcement = "Arranged \(bot.name) in \(sections[i].name)."
        } else {
            pendingMove = (bot, dest)
        }
    }

    // MARK: View transform

    private func setScale(_ next: Double, around p: CGPoint) {
        let z = TeamMapLogic.zoom(TeamMapTransform(x: view.x, y: view.y, scale: view.scale), to: next, around: CanvasPoint(x: p.x, y: p.y))
        view = TeamMapView_Transform(x: z.x, y: z.y, scale: z.scale)
    }

    private func fit() {
        let f = TeamMapLogic.fit(tiles, width: canvasSize.width, height: max(200, canvasSize.height - (visibleCount > 0 ? 96 : 0)))
        view = TeamMapView_Transform(x: f.x, y: f.y, scale: f.scale)
    }

    private func fitIfNeeded() {
        guard canvasSize.width > 100, !didFit else { return }
        didFit = true
        fit()
    }

    // MARK: Composer

    private var composer: some View {
        let targets = TeamMapLogic.targets(text: draft, bots: store.bots, state: store.teamMap)
        let delivery = TeamMapLogic.delivery(for: targets, bots: store.bots, state: store.teamMap)
        let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty && !targets.botIds.isEmpty
        let mention = currentMention
        return VStack(spacing: 6) {
            if let s = sentTo { sentBanner(s) }
            if let m = mention, !mentionChoices(m).isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(mentionChoices(m), id: \.self) { name in
                        Button { insertMention(name, replacing: m) } label: {
                            Text("@\(name)").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgCard))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderListRows))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message your bots: tag one with @, a department, or @everyone", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).font(.system(size: 15))
                    .foregroundStyle(Theme.textBright)
                    .onSubmit { send() }
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Theme.orange : Theme.textMuted.opacity(0.4)))
                }
                .buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send")
                .help(canSend ? "Send to \(delivery.botIds.count) bot\(delivery.botIds.count == 1 ? "" : "s")" : "Tag a bot, a department or @everyone")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.bgInputBar))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderInputsDark))
            if let hint = composerHint(targets, delivery: delivery) {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: 620)
        .opacity(visibleCount == 0 ? 0 : 1)
        .allowsHitTesting(visibleCount > 0)
    }

    private func composerHint(_ t: TeamMapTargets, delivery: (botIds: [String], chief: Bot?)) -> String? {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty && t.botIds.isEmpty { return "Tag a bot, a department or @everyone to send." }
        if let c = delivery.chief { return "Goes to \(c.name), who passes it on." }
        if !t.botIds.isEmpty { return t.botIds.count == 1 ? "Will send to 1 bot." : "Will send to \(t.botIds.count) bots." }
        return nil
    }

    private func sentBanner(_ s: (ids: [String], chief: String?)) -> some View {
        let names = s.ids.filter { $0 != s.chief }.compactMap { id in store.bots.first { $0.id == id }?.name }
        let sum = TeamMapLogic.sentSummary(names)
        var line = ""
        if let c = s.chief, let name = store.bots.first(where: { $0.id == c })?.name { line += "Sent via \(name)" + (names.isEmpty ? "" : " · ") }
        if !names.isEmpty { line += "Sent to " + sum.names.joined(separator: ", ") + (sum.more > 0 ? " and \(sum.more) more" : "") }
        return HStack {
            Text(line).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button { sentTo = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgCard.opacity(0.95)))
        .accessibilityLabel(line)
    }

    /// The `@word` being typed at the end of the draft, if any.
    private var currentMention: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, let before = draft[..<at].last, before.isLetter || before.isNumber { return nil }
        let tail = String(draft[draft.index(after: at)...])
        return tail.contains("\n") ? nil : tail
    }

    private func mentionChoices(_ query: String) -> [String] {
        var pool = store.bots.filter { !$0.hidden }.map(\.name)
        pool += sections.filter { !$0.key.isEmpty }.map(\.name)
        if visibleCount > 1 { pool.insert("everyone", at: 0) }
        let q = query.lowercased()
        let matches = pool.filter { q.isEmpty || $0.lowercased().hasPrefix(q) }.filter { $0.lowercased() != q }
        return Array(matches.prefix(6))
    }

    private func insertMention(_ name: String, replacing query: String) {
        if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) + "@\(name) " }
    }

    private func send() {
        let result = store.sendFromTeamMap(draft)
        guard !result.botIds.isEmpty else { return }
        draft = ""
        sentTo = (result.botIds, result.chief?.id)
        flash = Set(result.botIds)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            flash = []
        }
    }

    private func departmentSheet(title: String, text: Binding<String>, confirm: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textBright)
            TextField("Name", text: text).textFieldStyle(.roundedBorder).onSubmit(action)
            if !sheetError.isEmpty { Text(sheetError).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
            HStack {
                Spacer()
                Button("Cancel") { creating = false; renaming = nil }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                GrizzyButton(title: confirm, variant: .cream, size: .sm, disabled: text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty, action: action)
            }
        }
        .padding(24).frame(width: 380).background(Theme.bgRightPanel)
    }

    private struct Named: Identifiable { let name: String; var id: String { name } }
}

/// Local pan/zoom state (kept apart from the core `TeamMapView` value so the SwiftUI view can own its name).
struct TeamMapView_Transform: Equatable {
    var x = 0.0, y = 0.0, scale = 1.0
}

/// Two-finger scroll pans the canvas; pinch or ⌘-scroll zooms about the pointer.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (_ dx: Double, _ dy: Double, _ zoom: Bool, _ point: CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? CatcherView)?.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double, Double, Bool, CGPoint) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let zoom = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
                self.onScroll?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), zoom, CGPoint(x: p.x, y: self.bounds.height - p.y))
                return nil
            }
        }
    }
}
