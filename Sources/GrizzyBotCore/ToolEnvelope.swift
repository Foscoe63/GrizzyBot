import Foundation

/// Why a tool call failed, so the harness (not the model parsing prose) decides what happens next.
public enum ToolFailureKind: String, Sendable, Codable, CaseIterable {
    case invalidArgs = "invalid_args"
    case notFound = "not_found"
    case blocked = "blocked"
    case timeout = "timeout"
    case unavailable = "unavailable"
    case executionError = "execution_error"

    /// Whether trying the same call again might work.
    public var defaultRetryable: Bool {
        switch self {
        case .invalidArgs, .unavailable, .executionError: return true
        case .notFound, .blocked, .timeout: return false
        }
    }
}

public struct ToolFailure: Sendable, Equatable {
    public var kind: ToolFailureKind
    public var retryable: Bool
    public init(kind: ToolFailureKind, retryable: Bool? = nil) {
        self.kind = kind
        self.retryable = retryable ?? kind.defaultRetryable
    }
}

/// One JSON shape for tool results: `{ok:true, tool, result, warnings}` or
/// `{ok:false, kind, message, field, expected, tool, retryable}`.
public enum ToolEnvelope {
    public static func success(tool: String? = nil, text: String, warnings: [String] = []) -> String {
        success(tool: tool, result: .object(["text": .string(text)]), warnings: warnings)
    }

    public static func success(tool: String? = nil, result: JSONValue, warnings: [String] = []) -> String {
        var object: [String: JSONValue] = ["ok": .bool(true), "result": result]
        if let tool { object["tool"] = .string(tool) }
        if !warnings.isEmpty { object["warnings"] = .array(warnings.map { .string($0) }) }
        return encode(.object(object))
    }

    public static func failure(
        kind: ToolFailureKind,
        message: String,
        tool: String? = nil,
        field: String? = nil,
        expected: String? = nil,
        retryable: Bool? = nil
    ) -> String {
        var object: [String: JSONValue] = [
            "ok": .bool(false),
            "kind": .string(kind.rawValue),
            "message": .string(message),
            "retryable": .bool(retryable ?? kind.defaultRetryable),
        ]
        if let tool { object["tool"] = .string(tool) }
        if let field { object["field"] = .string(field) }
        if let expected { object["expected"] = .string(expected) }
        return encode(.object(object))
    }

    /// True when the string is a failure envelope.
    public static func isError(_ output: String) -> Bool { parseFailure(output) != nil }

    /// Reads a failure envelope back out of a tool result.
    public static func parseFailure(_ output: String) -> ToolFailure? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.contains("\"ok\"") else { return nil }
        let object = JSONValue.parseObject(trimmed)
        guard case .bool(false)? = object["ok"],
              case .string(let raw)? = object["kind"],
              let kind = ToolFailureKind(rawValue: raw) else { return nil }
        var retryable: Bool?
        if case .bool(let flag)? = object["retryable"] { retryable = flag }
        return ToolFailure(kind: kind, retryable: retryable)
    }

    /// Classifies the plain-text failures the existing tools already return. Returns nil for a result that
    /// does not look like a failure, so ordinary output is never relabelled.
    public static func classify(output: String) -> ToolFailure? {
        if let structured = parseFailure(output) { return structured }
        let lowered = output.prefix(400).lowercased()
        if lowered.contains("did not respond within") { return ToolFailure(kind: .timeout) }
        if lowered.hasPrefix("blocked") || lowered.contains("denied by") || lowered.contains("was denied")
            || lowered.contains("not allowed") || lowered.contains("permission denied") {
            return ToolFailure(kind: .blocked)
        }
        if lowered.hasPrefix("missing") || lowered.contains("missing required") || lowered.contains("invalid argument")
            || lowered.contains("expected a") || lowered.hasPrefix("no such argument") {
            return ToolFailure(kind: .invalidArgs)
        }
        if lowered.contains("no such file") || lowered.contains("not found") || lowered.contains("does not exist")
            || lowered.hasPrefix("no saved") || lowered.hasPrefix("no bot named") {
            return ToolFailure(kind: .notFound)
        }
        if lowered.contains("is disabled") || lowered.contains("not connected") || lowered.contains("unavailable")
            || lowered.contains("isn't turned on") {
            return ToolFailure(kind: .unavailable, retryable: false)
        }
        if lowered.hasPrefix("error") || lowered.contains(" failed") || lowered.hasPrefix("failed")
            || lowered.contains("couldn't") || lowered.contains("could not") {
            return ToolFailure(kind: .executionError)
        }
        return nil
    }

    private static func encode(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Retry and bias layer: remembers failures per run so the harness can tell the model, in plain words,
/// when to stop repeating a call that cannot work.
public final class ToolRetryGuard: @unchecked Sendable {
    public static let shared = ToolRetryGuard()
    /// The same call failing this many times in a row ends retrying.
    public static let repeatLimit = 3

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var order: [String] = []
    private let capacity = 400

    public init() {}

    private func key(run: String, tool: String, arguments: String) -> String {
        "\(run)|\(tool)|\(arguments.hashValue)"
    }

    /// Records the outcome of a call and returns a hint to append for the model, if one is warranted.
    public func note(run: String, tool: String, arguments: String, output: String) -> String? {
        let k = key(run: run, tool: tool, arguments: arguments)
        guard let failure = ToolEnvelope.classify(output: output) else {
            lock.lock(); counts[k] = nil; lock.unlock()
            return nil
        }
        lock.lock()
        let count = (counts[k] ?? 0) + 1
        counts[k] = count
        if count == 1 { order.append(k) }
        if order.count > capacity, let oldest = order.first {
            order.removeFirst()
            counts[oldest] = nil
        }
        lock.unlock()
        if count >= Self.repeatLimit {
            return "This exact call has now failed \(count) times (\(failure.kind.rawValue)). Stop repeating it: change the arguments or the approach, or tell the person what is stuck."
        }
        if !failure.retryable {
            switch failure.kind {
            case .notFound: return "Not found: check the name or path with a listing before trying again."
            case .timeout: return "Timed out: do not retry the same call."
            case .blocked: return "Blocked: do not retry; ask the person or use another route."
            default: return "Not retryable as is: change the approach."
            }
        }
        if failure.kind == .invalidArgs { return "Invalid arguments: fix them, then retry once." }
        return nil
    }

    public func reset(run: String) {
        lock.lock()
        let prefix = "\(run)|"
        counts = counts.filter { !$0.key.hasPrefix(prefix) }
        order.removeAll { $0.hasPrefix(prefix) }
        lock.unlock()
    }
}
