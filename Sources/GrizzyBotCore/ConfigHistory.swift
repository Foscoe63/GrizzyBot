import Foundation

/// One recorded change to the app settings, with enough of the old values to undo it. Keys that hold
/// secrets are noted as changed but their values are never stored here and never restored.
public struct ConfigChange: Codable, Sendable, Equatable, Identifiable {
    public struct Item: Codable, Sendable, Equatable {
        public var key: String
        public var before: JSONValue?
        public var after: JSONValue?
        public var secret: Bool
    }
    public var id: String
    public var at: Date
    /// Where the change came from: `settings` (the person) or `assistant` (a bot, after approval).
    public var source: String
    public var items: [Item]

    public var summary: String {
        items.map { $0.secret ? "\($0.key) (secret)" : $0.key }.joined(separator: ", ")
    }
    /// A change that only touched secrets has nothing to undo.
    public var revertible: Bool { items.contains { !$0.secret } }
}

public enum ConfigHistory {
    public static let cap = 100

    public static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["key", "token", "secret", "dsn", "password"].contains { k.contains($0) }
    }

    private static func dictionary(_ config: AppConfig) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(config),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else { return [:] }
        return object
    }

    /// What changed between two configs, or nil when nothing did.
    public static func diff(old: AppConfig, new: AppConfig, source: String = "settings", at: Date = .now) -> ConfigChange? {
        let a = dictionary(old), b = dictionary(new)
        var items: [ConfigChange.Item] = []
        for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
            let secret = isSecretKey(key)
            items.append(.init(key: key, before: secret ? nil : a[key], after: secret ? nil : b[key], secret: secret))
        }
        return items.isEmpty ? nil : ConfigChange(id: Ids.new(), at: at, source: source, items: items)
    }

    /// The config with this change undone. Secret keys are left as they are now.
    public static func reverted(_ change: ConfigChange, from config: AppConfig) -> AppConfig? {
        var object = dictionary(config)
        for item in change.items where !item.secret {
            if let before = item.before { object[item.key] = before } else { object.removeValue(forKey: item.key) }
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    public static func appending(_ history: [ConfigChange], _ change: ConfigChange) -> [ConfigChange] {
        Array((history + [change]).suffix(cap))
    }
}
