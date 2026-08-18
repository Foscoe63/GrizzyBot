import AppKit
import Combine
import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController
    #endif

    @Published var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates
            #else
            false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    private override init() {
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
        super.init()
        #if canImport(Sparkle)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    func start() {
        #if canImport(Sparkle)
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }
}

struct UpdatesSettingsView: View {
    var body: some View {
        let updater = UpdaterManager.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            .toggleStyle(.switch)
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSidebarIcon)
            .disabled(!updater.canCheckForUpdates)
            Text("Feed: GitHub appcast. A newer build installs only after Scripts/publish-update.sh adds a signed DMG item.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
