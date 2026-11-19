import Foundation

/// Cross-step runaway detector for the agent loop. Complements the per-step dedupe in
/// `AgentLoop.executeCalls` and the per-call hints in `ToolRetryGuard`: it watches the
/// whole turn and decides to warn once, then stop.
public struct ToolLoopGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        case ok
        case warn(String)
        case stop(String)
    }

    public struct Limits: Sendable {
        public var failingWarn = 3, failingStop = 6
        public var sameResultWarn = 6, sameResultStop = 12
        public var similarWarn = 15, similarStop = 25
        public init() {}
    }

    public static let exemptTools: Set<String> = ["todo", "complete", "clarify", "capabilities_discover", "capabilities_load"]

    private let limits: Limits
    private var lastKey: String?
    private var lastResult: String?
    private var identical = 0
    private var failing = 0
    private var lastShape: String?
    private var similar = 0
    private var warned: Set<String> = []

    public init(limits: Limits = Limits()) { self.limits = limits }

    /// Record one executed call. Returns what the loop should do next.
    public mutating func record(tool: String, arguments: String, output: String) -> Verdict {
        if Self.exemptTools.contains(tool) || output.hasPrefix("Skipped") { return .ok }
        let args = Self.canonical(arguments)
        let key = tool + "\n" + args
        let result = Self.fingerprint(output)
        let failed = ToolEnvelope.classify(output: output) != nil

        let sameKey = key == lastKey
        let freshPoll = sameKey && !failed && result != lastResult
        if key == lastKey {
            if result == lastResult || failed {
                identical += 1
            } else {
                identical = 1  // fresh result on the same call: polling, not looping
            }
        } else {
            identical = 1
            failing = 0
            warned.removeAll()
        }
        failing = failed ? (key == lastKey ? failing + 1 : 1) : 0
        lastKey = key
        lastResult = result

        let shape = tool + "\n" + Self.shape(args)
        similar = freshPoll ? 1 : (shape == lastShape ? similar + 1 : 1)
        lastShape = shape

        let label = tool
        if failing >= limits.failingStop {
            return .stop("\(label) failed \(failing) times in a row with the same arguments")
        }
        if identical >= limits.sameResultStop {
            return .stop("\(label) returned the same result \(identical) times in a row")
        }
        if similar >= limits.similarStop {
            return .stop("\(label) was called \(similar) times in a row with near-identical arguments")
        }
        if failing >= limits.failingWarn, warned.insert("f").inserted {
            return .warn("\(label) has failed \(failing) times with the same arguments. Change the arguments or approach, or tell the person what is stuck.")
        }
        if identical >= limits.sameResultWarn, warned.insert("i").inserted {
            return .warn("\(label) keeps returning the same result. Use what you have, try a different approach, or finish.")
        }
        if similar >= limits.similarWarn, warned.insert("s").inserted {
            return .warn("You have called \(label) \(similar) times in a row with near-identical arguments. Confirm this is making progress, otherwise change approach or finish.")
        }
        return .ok
    }

    static func canonical(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed]),
              let s = String(data: out, encoding: .utf8) else { return trimmed }
        return s
    }

    static func shape(_ canonical: String) -> String {
        var out = ""
        var inDigits = false
        for ch in canonical {
            if ch.isNumber {
                if !inDigits { out.append("#") }
                inDigits = true
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out
    }

    static func fingerprint(_ output: String) -> String {
        "\(output.count):\(output.hashValue)"
    }
}
