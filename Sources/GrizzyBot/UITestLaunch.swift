import Foundation
import GrizzyBotCore

enum OverlayA11y {
    static let settings = "settings-overlay"
    static let plugins = "plugins-overlay"
    static let skills = "skills-overlay"
    static let model = "model-overlay"
}

enum UITestLaunch {
    /// xcodebuild injects these before the host app finishes launching.
    static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCInjectBundleInto"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }

    static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest")
    }

    static func dataDirectory() -> URL? {
        guard isUITest else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBot-UITest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    static func apply(_ store: AppStore) {
        let args = ProcessInfo.processInfo.arguments
        if isUITest {
            store.prepareUITestWorkspace()
        }
        if args.contains("-uitest-open-settings") {
            store.openAppSettings()
        }
        if args.contains("-uitest-open-plugins") {
            store.pluginsOpen = true
        }
        if args.contains("-uitest-open-skills") {
            store.skillsOpen = true
        }
        if args.contains("-uitest-open-model") {
            store.openModelSettings()
        }
    }
}
