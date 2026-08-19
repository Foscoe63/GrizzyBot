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
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return on ? .enabled : .disabled
        } catch {
            #if DEBUG
            return .unavailableInDebug
            #else
            return .failed(error.localizedDescription)
            #endif
        }
    }
}

enum RoutineAgentController {
    private static let agentPlist = "com.grizzybot.routine-agent"

    static var isRegistered: Bool {
        SMAppService.agent(plistName: agentPlist).status == .enabled
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> LoginItemResult {
        let service = SMAppService.agent(plistName: agentPlist)
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            return on ? .enabled : .disabled
        } catch {
            #if DEBUG
            return .unavailableInDebug
            #else
            return .failed(error.localizedDescription)
            #endif
        }
    }
}
