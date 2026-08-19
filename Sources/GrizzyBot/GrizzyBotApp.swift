import AppKit
import GrizzyBotCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isHeadlessRoutineTick: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArguments.tickRoutines)
    }

    private var tickObserver: NSObjectProtocol?
    var onRoutineTick: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if UITestLaunch.isTestHost {
            NSApp.setActivationPolicy(.regular)
            return
        }
        if Self.isHeadlessRoutineTick {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.showMainWindow()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UITestLaunch.isTestHost { return }
        CrashReporting.prepare()
        registerRoutineTickListener()
        if Self.isHeadlessRoutineTick {
            for window in NSApp.windows {
                window.orderOut(nil)
            }
        }
    }

    private func registerRoutineTickListener() {
        tickObserver = DistributedNotificationCenter.default().addObserver(
            forName: RoutineTickIPC.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onRoutineTick?()
            }
        }
    }
}

@main
struct GrizzyBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeManager = ThemeManager()
    @State private var store: AppStore = {
        if UITestLaunch.isTestHost {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GrizzyBot-TestHost", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return AppStore(dataDirectory: dir, delayScale: 0.01)
        }
        let store = AppStore(dataDirectory: UITestLaunch.dataDirectory())
        store.computerRuntime = AppComputerRuntime.shared
        if AppDelegate.isHeadlessRoutineTick {
            store.headlessRoutineTick = true
        }
        return store
    }()

    var body: some Scene {
        WindowGroup {
            ThemePaletteProvider {
                windowRoot
            }
            .environment(store)
            .environment(themeManager)
            .onAppear {
                guard !UITestLaunch.isTestHost else { return }
                themeManager.load(from: store.appConfig)
                appDelegate.onRoutineTick = { store.tickDueRoutines() }
            }
            .onChange(of: store.appConfig.activeThemePresetId) { _, _ in
                themeManager.load(from: store.appConfig)
            }
            .onChange(of: store.appConfig.themeAppearanceMode) { _, _ in
                themeManager.load(from: store.appConfig)
            }
        }
        .defaultSize(width: windowWidth, height: windowHeight)
        .commands { appCommands }

        MenuBarExtra("GrizzyBot", systemImage: "hexagon.fill", isInserted: menuBarInserted) {
            ThemePaletteProvider {
                MenuBarView()
            }
            .environment(store)
            .environment(themeManager)
        }
        .menuBarExtraStyle(.menu)
    }

    private var windowWidth: CGFloat {
        if UITestLaunch.isTestHost || AppDelegate.isHeadlessRoutineTick { return 1 }
        return 1280
    }
    private var windowHeight: CGFloat {
        if UITestLaunch.isTestHost || AppDelegate.isHeadlessRoutineTick { return 1 }
        return 832
    }

    @ViewBuilder
    private var windowRoot: some View {
        if UITestLaunch.isTestHost {
            Color.clear.frame(width: 1, height: 1)
        } else if AppDelegate.isHeadlessRoutineTick {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { runHeadlessTick() }
        } else {
            RootView()
                .frame(minWidth: 1080, minHeight: 720)
                .grizzyWindowChrome()
                .onAppear { configureMainWindow() }
        }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Find in Chats") {
                store.openChatSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Undo Send") {
                if let botId = store.activeBotId {
                    _ = store.undoSend(botId: botId)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button("Diagnostics") {
                store.openAppSettings(section: .diagnostics)
            }
        }
    }

    @MainActor
    private func configureMainWindow() {
        UITestLaunch.apply(store)
        CrashReporting.install(dsn: store.appConfig.sentryDSN)
        FinishNotifier.requestAccess()
        store.onRunFinished = { bot, text in
            if bot.speakReplies {
                ReplySpeaker.speak(
                    text,
                    voiceName: store.appConfig.ttsVoice,
                    apiKey: store.appConfig.ttsKey
                )
            }
            if bot.notifyOnFinish && bot.notifications {
                FinishNotifier.notify(bot: bot.name, text: text)
            }
        }
        store.startRoutineScheduler()
        if store.appConfig.launchAtLogin {
            _ = LoginItemController.setEnabled(true)
        }
        if store.appConfig.backgroundRoutines {
            _ = RoutineAgentController.setEnabled(true)
        }
        if store.appConfig.menuBarOnly {
            MainWindowController.applyMenuBarOnly(true)
        }
    }

    @MainActor
    private func runHeadlessTick() {
        CrashReporting.install(dsn: store.appConfig.sentryDSN)
        if otherGrizzyBotRunning() {
            DistributedNotificationCenter.default().post(name: RoutineTickIPC.notification, object: nil)
            NSApp.terminate(nil)
            return
        }
        Task { @MainActor in
            store.tickDueRoutines()
            await store.waitForActiveRuns(timeout: 900)
            NSApp.terminate(nil)
        }
    }

    private func otherGrizzyBotRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: RoutineTickIPC.bundleId)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: {
                if UITestLaunch.isTestHost || AppDelegate.isHeadlessRoutineTick { return false }
                return store.appConfig.showMenuBar
            },
            set: { value in
                var config = store.appConfig
                config.showMenuBar = value
                store.saveAppConfig(config)
            }
        )
    }
}
