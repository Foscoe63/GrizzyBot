import Foundation

/// The settings a bot may change on a person's behalf, each with its allowed values. Everything that
/// guards the person (privacy rules, policies, secrets, permissions) is deliberately absent.
public enum ConfigAssistant {
    public struct Setting: Sendable {
        public var key: String
        public var summary: String
        public var allowed: String
        var read: @Sendable (AppConfig) -> String
        var write: @Sendable (inout AppConfig, String) -> Bool
    }

    private static func bool(_ raw: String) -> Bool? {
        switch raw.lowercased() { case "true", "on", "yes", "1": return true; case "false", "off", "no", "0": return false; default: return nil }
    }

    public static let settings: [Setting] = [
        Setting(key: "agentStallTimeoutMs", summary: "How long a model stream may stay silent before it is cut (0 = never)", allowed: "0–600000 (milliseconds)",
                read: { String($0.agentStallTimeoutMs) },
                write: { c, v in guard let n = Int(v), (0...600_000).contains(n) else { return false }; c.agentStallTimeoutMs = n; return true }),
        Setting(key: "memoryRelevanceMode", summary: "When memory is added to a turn", allowed: "always, heuristic, off",
                read: { $0.memoryRelevanceMode.rawValue },
                write: { c, v in guard let m = MemoryRelevanceGateMode(rawValue: v.lowercased()) else { return false }; c.memoryRelevanceMode = m; return true }),
        Setting(key: "queueMode", summary: "What a message sent mid-run does", allowed: QueueMode.allCases.map(\.rawValue).joined(separator: ", "),
                read: { $0.queueMode.rawValue },
                write: { c, v in guard let m = QueueMode(rawValue: v.lowercased()) else { return false }; c.queueMode = m; return true }),
        Setting(key: "themeAppearanceMode", summary: "Light, dark or system appearance", allowed: ThemeAppearanceMode.allCases.map(\.rawValue).joined(separator: ", "),
                read: { $0.themeAppearanceMode.rawValue },
                write: { c, v in guard let m = ThemeAppearanceMode(rawValue: v.lowercased()) else { return false }; c.themeAppearanceMode = m; return true }),
        Setting(key: "showMenuBar", summary: "Show GrizzyBot in the menu bar", allowed: "true, false",
                read: { String($0.showMenuBar) },
                write: { c, v in guard let b = bool(v) else { return false }; c.showMenuBar = b; return true }),
        Setting(key: "menuBarOnly", summary: "Hide the main window at launch", allowed: "true, false",
                read: { String($0.menuBarOnly) },
                write: { c, v in guard let b = bool(v) else { return false }; c.menuBarOnly = b; return true }),
        Setting(key: "privacyOnDeviceDetection", summary: "Also find names, places and organisations before a cloud send", allowed: "true, false",
                read: { String($0.privacyFilter.useOnDeviceNER) },
                write: { c, v in guard let b = bool(v) else { return false }; c.privacyFilter.useOnDeviceNER = b; return true }),
    ]

    public static func describe(_ config: AppConfig) -> String {
        settings.map { "- \($0.key) = \($0.read(config)) — \($0.summary) (\($0.allowed))" }.joined(separator: "\n")
    }

    public static func value(of key: String, in config: AppConfig) -> String? {
        settings.first { $0.key == key }?.read(config)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unknownKey(String)
        case badValue(key: String, allowed: String)
        public var errorDescription: String? {
            switch self {
            case .unknownKey(let k): return "“\(k)” isn't a setting a bot can change. Use action=list to see which are."
            case .badValue(let k, let allowed): return "That isn't a valid value for \(k). Allowed: \(allowed)."
            }
        }
    }

    public static func applying(key: String, value: String, to config: AppConfig) throws -> AppConfig {
        guard let setting = settings.first(where: { $0.key == key }) else { throw Failure.unknownKey(key) }
        var next = config
        guard setting.write(&next, value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure.badValue(key: key, allowed: setting.allowed) }
        return next
    }
}
