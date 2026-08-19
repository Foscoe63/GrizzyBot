import Foundation

/// Redact secrets and home paths from diagnostics text (run logs, crash reports, pasteboard).
public enum DiagnosticScrubber {
    private static let keyPattern = try! NSRegularExpression(
        pattern: "(?i)(api[_-]?key|token|secret|password|dsn|authorization|bearer|sk-[a-z0-9]{8,})[^\\s]*",
        options: []
    )
    private static let pathPattern = try! NSRegularExpression(
        pattern: "(/Users/[^\\s\"']+|~/[^\\s\"']+|/Volumes/[^\\s\"']+)",
        options: []
    )

    public static func redact(_ text: String) -> String {
        var out = text
        out = replace(keyPattern, in: out, with: "[redacted]")
        out = replace(pathPattern, in: out, with: "[path]")
        return out
    }

    public static func redactAny(_ value: Any) -> Any {
        if let string = value as? String {
            return redact(string)
        }
        if let dict = value as? [String: Any] {
            var next: [String: Any] = [:]
            for (key, nested) in dict {
                next[key] = redactAny(nested)
            }
            return next
        }
        if let array = value as? [Any] {
            return array.map { redactAny($0) }
        }
        if let dict = value as? [AnyHashable: Any] {
            var next: [AnyHashable: Any] = [:]
            for (key, nested) in dict {
                next[key] = redactAny(nested)
            }
            return next
        }
        return value
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
