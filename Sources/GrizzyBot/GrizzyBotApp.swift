import AppKit
import GrizzyBotCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterManager = UpdaterManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporting.prepare()
        updaterManager.start()
    }
}

@main
struct GrizzyBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore = {
        let store = AppStore(dataDirectory: UITestLaunch.dataDirectory())
        store.computerRuntime = AppComputerRuntime.shared
        return store
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 1080, minHeight: 720)
                .grizzyWindowChrome()
                .onAppear {
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
                        LoginItemController.setEnabled(true)
                    }
                }
        }
        .defaultSize(width: 1280, height: 832)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterManager.shared.checkForUpdates()
                }
            }
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

        MenuBarExtra("GrizzyBot", systemImage: "hexagon.fill", isInserted: menuBarInserted) {
            MenuBarView()
                .environment(store)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { store.appConfig.showMenuBar },
            set: { value in
                var config = store.appConfig
                config.showMenuBar = value
                store.saveAppConfig(config)
            }
        )
    }
}
