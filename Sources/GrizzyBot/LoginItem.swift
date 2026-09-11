import Foundation
import ServiceManagement

enum LoginItemResult: Equatable {
    case enabled
    case disabled
    case unavailableInDebug
    case failed(String)
}

enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusMessage: String {
        #if DEBUG
        if SMAppService.mainApp.status != .enabled {
            return "Launch at login requires a signed Release build. Debug builds cannot register a login item."
        }
        #endif
        switch SMAppService.mainApp.status {
        case .enabled: return "GrizzyBot opens at login."
        case .requiresApproval: return "Approve GrizzyBot in System Settings → Login Items."
        case .notRegistered: return "Not registered."
        default: return "Status: \(SMAppService.mainApp.status.rawValue)"
        }
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> LoginItemResult {
        #if DEBUG
        return .unavailableInDebug
        #else
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return on ? .enabled : .disabled
        } catch {
            return .failed(error.localizedDescription)
        }
        #endif
    }
}

enum RoutineAgentController {
    private static let agentPlist = "com.grizzybot.routine-agent"

    /// LaunchAgent plist must live at `App.app/Contents/Library/LaunchAgents/<name>.plist`.
    private static var bundledPlistURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlist).plist", isDirectory: false)
    }

    private static var hasBundledPlist: Bool {
        guard let url = bundledPlistURL else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    static var isRegistered: Bool {
        #if DEBUG
        // Ad-hoc Debug apps cannot register Launch Agents; probing SMAppService only logs noise.
        return false
        #else
        guard hasBundledPlist else { return false }
        return SMAppService.agent(plistName: agentPlist).status == .enabled
        #endif
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> LoginItemResult {
        #if DEBUG
        return .unavailableInDebug
        #else
        guard hasBundledPlist else {
            return .failed("Routine agent plist missing from the app bundle (Contents/Library/LaunchAgents/\(agentPlist).plist).")
        }
        let service = SMAppService.agent(plistName: agentPlist)
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            return on ? .enabled : .disabled
        } catch {
            return .failed(error.localizedDescription)
        }
        #endif
    }
}
