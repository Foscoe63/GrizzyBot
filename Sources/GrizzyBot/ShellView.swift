import GrizzyBotCore
import SwiftUI

struct ShellView: View {
    @Environment(AppStore.self) private var store
    @State private var heartbeatTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 316)

                Group {
                    if store.mainView == .routines {
                        RoutinesPageView()
                    } else {
                        ChatView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bgMain)

                RightPanelView()
                    .frame(width: store.panel == nil ? 0 : 384)
                    .frame(maxHeight: .infinity)
                    .background(Theme.bgRightPanel)
                    .overlay(alignment: .leading) {
                        if store.panel != nil {
                            Rectangle()
                                .fill(Theme.borderMainHdr)
                                .frame(width: 1)
                        }
                    }
                    .clipped()
                    .animation(.easeInOut(duration: 0.2), value: store.panel)
            }

            if store.showHostPrompt {
                HostComputerPromptView()
                    .zIndex(10)
            }
            if store.pluginsOpen {
                PluginsOverlayView()
                    .zIndex(20)
            }
            if store.modelSettingsOpen {
                ModelSettingsOverlayView()
                    .zIndex(25)
            }
            if store.appSettingsOpen {
                AppSettingsOverlayView()
                    .zIndex(28)
            }
            if store.booting {
                BootingOverlay(name: store.activeBot?.name ?? "bot")
                    .zIndex(30)
            }
            if store.computerOpen {
                ComputerFullWindowOverlay()
                    .zIndex(40)
            }
        }
        .background(Theme.bgApp)
        .focusable()
        .onKeyPress(.escape) {
            if store.computerOpen {
                store.closeComputerOverlay()
                return .handled
            }
            if store.appSettingsOpen {
                store.closeAppSettings()
                return .handled
            }
            if store.modelSettingsOpen {
                store.closeModelSettings()
                return .handled
            }
            if store.pluginsOpen {
                store.pluginsOpen = false
                return .handled
            }
            if store.mainView == .routines {
                store.showChat()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "nN"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            store.openPanel(.create)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789"), phases: .down) { press in
            guard press.modifiers.contains(.command),
                  !press.modifiers.contains(.shift),
                  let ch = press.characters.first,
                  let n = Int(String(ch)) else { return .ignored }
            store.selectBotByIndex(n - 1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]"), phases: .down) { press in
            guard press.modifiers.contains(.command), press.modifiers.contains(.shift),
                  let ch = press.characters.first else {
                return .ignored
            }
            store.selectAdjacentBot(delta: ch == "[" ? -1 : 1)
            return .handled
        }
        .onChange(of: store.activeBotId) { _, _ in
            store.closeComputerOverlay()
        }
        .onChange(of: store.panel) { _, _ in
            restartHeartbeat()
        }
        .onChange(of: store.computerOpen) { _, _ in
            restartHeartbeat()
        }
        .onAppear { restartHeartbeat() }
        .onDisappear {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// rakazo pings `computer.heartbeat` every 60s while panel or overlay is open and running.
    private func restartHeartbeat() {
        heartbeatTask?.cancel()
        guard store.panel == .computer || store.computerOpen,
              let botId = store.activeBotId,
              store.computers[botId]?.state == .running else {
            heartbeatTask = nil
            return
        }
        heartbeatTask = Task { @MainActor in
            store.heartbeat(botId: botId)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard store.panel == .computer || store.computerOpen,
                      store.computers[botId]?.state == .running else { return }
                store.heartbeat(botId: botId)
            }
        }
    }
}

private struct BootingOverlay: View {
    let name: String
    @State private var offset: CGFloat = -1

    var body: some View {
        ZStack {
            Color(red: 4 / 255, green: 4 / 255, blue: 5 / 255).opacity(0.96)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Text("Booting up \(name)'s computer")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.textBrightAlt)
                GeometryReader { geo in
                    let trackW = min(420, geo.size.width * 0.7)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.bgProgressTrack)
                            .frame(width: trackW, height: 5)
                        Capsule()
                            .fill(Theme.bgCream)
                            .frame(width: trackW * 2 / 3, height: 5)
                            .offset(x: offset * trackW * 0.35)
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                            offset = 1
                        }
                    }
                }
                .frame(height: 5)
                .frame(maxWidth: 420)
            }
        }
    }
}

private struct ComputerFullWindowOverlay: View {
    @Environment(AppStore.self) private var store

    private var bot: Bot? { store.activeBot }
    private var computer: ComputerStatus? {
        guard let id = bot?.id else { return nil }
        return store.computers[id]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let bot {
                    BotAvatarView(color: bot.color, size: 28)
                    Text("\(bot.name)'s computer")
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(Theme.textBright)
                        .lineLimit(1)
                    if computer?.controlHolder == .user {
                        Text("You have control")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(Color(hex: "#30A24B").opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                if let bot {
                    if computer?.controlHolder == .user {
                        GrizzyButton(title: "Release", variant: .outline, size: .sm) {
                            store.release(botId: bot.id)
                        }
                    } else {
                        GrizzyButton(title: "Take control", variant: .outline, size: .sm) {
                            store.takeControl(botId: bot.id)
                        }
                    }
                }
                Button {
                    store.closeComputerOverlay()
                } label: {
                    Text("✕")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.bgApp)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.borderSidebar).frame(height: 1)
            }

            ZStack {
                Theme.bgScreen
                bodyContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bgApp)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let computer, computer.kind == .desktop {
            Text("This bot runs on this computer. There is no separate Linux desktop. Ask it to use the shell; working directories under your home folder are allowed.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(40)
                .frame(maxWidth: 520)
        } else if computer?.state == .suspended {
            Text("Computer is asleep")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textMuted)
        } else if computer?.state == .running {
            Text("\(bot?.name ?? "Bot")'s screen")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textMuted)
        } else {
            Text("Computer is stopped")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
