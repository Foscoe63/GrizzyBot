import Foundation

/// Secrets a bot may use without ever seeing: the person types the value into a native field, it goes
/// to the Keychain, and the bot writes `{{secret:NAME}}` where the value belongs. GrizzyBot swaps the
/// real value in at the last moment, on this Mac, and scrubs it from whatever comes back.
public enum SecretPlaceholders {
    static let pattern = #"\{\{secret:([A-Za-z0-9_.-]{1,64})\}\}"#

    public static func names(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, range: range).compactMap { match -> String? in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
        return Array(NSOrderedSet(array: found)) as? [String] ?? found
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil
    }

    /// Replaces each placeholder using `lookup`. `missing` lists names that had no value.
    public static func substitute(_ text: String, lookup: (String) -> String?) -> (text: String, missing: [String]) {
        var out = text
        var missing: [String] = []
        for name in names(in: text) {
            if let value = lookup(name), !value.isEmpty {
                out = out.replacingOccurrences(of: "{{secret:\(name)}}", with: value)
            } else {
                missing.append(name)
            }
        }
        return (out, missing)
    }

    // MARK: - Shell
    //
    // A shell command is shown on the approval card, so the value can never be written into it.
    // Instead each placeholder becomes a reference to an environment variable, and the value is
    // handed to the process through its environment only.

    public static let shellPrefix = "GRIZZY_SECRET_"

    public static func environmentName(for secret: String) -> String {
        shellPrefix + secret.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    /// `echo {{secret:API_KEY}}` → `echo "$GRIZZY_SECRET_API_KEY"`. Placeholders already inside
    /// double quotes keep their quotes (no doubled quoting).
    public static func rewriteForShell(_ command: String) -> String {
        var out = command
        for name in names(in: command) {
            let reference = "$" + environmentName(for: name)
            out = out.replacingOccurrences(of: "\"{{secret:\(name)}}\"", with: "\"\(reference)\"")
            out = out.replacingOccurrences(of: "{{secret:\(name)}}", with: "\"\(reference)\"")
        }
        return out
    }

    /// The environment a rewritten command needs, from the secrets this bot actually has.
    public static func shellEnvironment(for command: String, secretNames: [String], lookup: (String) -> String?) -> [String: String] {
        var env: [String: String] = [:]
        for name in secretNames {
            let key = environmentName(for: name)
            guard command.contains(key), let value = lookup(name), !value.isEmpty else { continue }
            env[key] = value
        }
        return env
    }

    /// Tools whose arguments never appear in an approval card, so injecting a secret there cannot show it.
    public static func canInject(into tool: String) -> Bool {
        switch tool {
        case "web_fetch", "plugin_call", "mcp_call", "destination_write", "toolport_call_tool", "call_tool_by_name", "shell":
            return true
        default:
            return tool.contains("__")
        }
    }
}
