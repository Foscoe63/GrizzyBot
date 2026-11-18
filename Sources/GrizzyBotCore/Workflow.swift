import Foundation

// A workflow is a fixed, acyclic graph of steps with typed input. Every step is declarative, so a person
// can read what it does before it runs, and the runner records what each step did.

public enum WorkflowNodeKind: String, Codable, Sendable {
    /// Call one of the bot's tools (it goes through the usual approvals and guards).
    case tool
    /// Ask the model, optionally for one of a fixed set of options (`decide`).
    case inference
    /// An http(s) request.
    case http
}

public enum WorkflowErrorPolicy: String, Codable, Sendable {
    case fail, `continue`, skip
}

public enum WorkflowJoin: String, Codable, Sendable {
    case any, all
}

public struct WorkflowNode: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: WorkflowNodeKind
    /// tool: the tool name.
    public var tool: String?
    /// tool: arguments; http: `url`, `method`, `body`; inference: unused.
    public var args: [String: String]
    /// inference: the instructions. Bindings are filled in first.
    public var prompt: String?
    /// inference: when set, the answer must be one of these.
    public var options: [String]
    public var timeoutSeconds: Double
    public var maxAttempts: Int
    public var backoffSeconds: Double
    public var onError: WorkflowErrorPolicy
    public var join: WorkflowJoin

    public init(
        id: String, name: String = "", kind: WorkflowNodeKind, tool: String? = nil, args: [String: String] = [:],
        prompt: String? = nil, options: [String] = [], timeoutSeconds: Double = 120, maxAttempts: Int = 1,
        backoffSeconds: Double = 1, onError: WorkflowErrorPolicy = .fail, join: WorkflowJoin = .any
    ) {
        self.id = id; self.name = name.isEmpty ? id : name; self.kind = kind; self.tool = tool; self.args = args
        self.prompt = prompt; self.options = options; self.timeoutSeconds = timeoutSeconds
        self.maxAttempts = max(1, maxAttempts); self.backoffSeconds = backoffSeconds; self.onError = onError; self.join = join
    }
}

/// A test on the source step's output: `path` is a dotted path into it (empty = the whole output).
public struct WorkflowCondition: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable { case equals, notEquals, contains, exists }
    public var path: String
    public var op: Op
    public var value: String

    public init(path: String = "", op: Op, value: String = "") {
        self.path = path; self.op = op; self.value = value
    }

    func holds(for output: JSONValue) -> Bool {
        let found = WorkflowBindings.lookup(path.isEmpty ? [] : path.split(separator: ".").map(String.init), in: output)
        switch op {
        case .exists: return found != nil && found != .null
        case .equals: return found.map { WorkflowBindings.text($0).lowercased() == value.lowercased() } ?? false
        case .notEquals: return found.map { WorkflowBindings.text($0).lowercased() != value.lowercased() } ?? true
        case .contains: return found.map { WorkflowBindings.text($0).lowercased().contains(value.lowercased()) } ?? false
        }
    }
}

public struct WorkflowEdge: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable { case success, error, always }
    public var from: String
    public var to: String
    public var when: WorkflowCondition?
    public var on: Trigger

    public init(from: String, to: String, when: WorkflowCondition? = nil, on: Trigger = .success) {
        self.from = from; self.to = to; self.when = when; self.on = on
    }
}

public struct WorkflowRequirements: Codable, Sendable, Equatable {
    public var tools: [String]
    public var secrets: [String]
    public init(tools: [String] = [], secrets: [String] = []) { self.tools = tools; self.secrets = secrets }
}

public struct WorkflowDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// Input field name → what it is. Every field is required unless it has a default in `defaults`.
    public var inputs: [String: String]
    public var defaults: [String: String]
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    /// How the result is assembled from the steps: name → binding template.
    public var output: [String: String]
    public var requires: WorkflowRequirements

    public init(
        id: String, name: String, summary: String = "", inputs: [String: String] = [:], defaults: [String: String] = [:],
        nodes: [WorkflowNode], edges: [WorkflowEdge] = [], output: [String: String] = [:], requires: WorkflowRequirements = .init()
    ) {
        self.id = id; self.name = name; self.summary = summary; self.inputs = inputs; self.defaults = defaults
        self.nodes = nodes; self.edges = edges; self.output = output; self.requires = requires
    }
}

public enum WorkflowError: Error, LocalizedError, Equatable {
    case invalid(String)
    case missingInput([String])

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): return "That workflow isn't valid: \(why)"
        case .missingInput(let names): return "This workflow needs: \(names.joined(separator: ", "))."
        }
    }
}

public enum WorkflowValidator {
    public static let maxNodes = 40

    /// The nodes in an order where every step comes after the steps feeding it.
    public static func order(_ def: WorkflowDefinition) throws -> [WorkflowNode] {
        guard !def.nodes.isEmpty else { throw WorkflowError.invalid("it has no steps") }
        guard def.nodes.count <= maxNodes else { throw WorkflowError.invalid("it has more than \(maxNodes) steps") }
        let ids = def.nodes.map(\.id)
        guard Set(ids).count == ids.count else { throw WorkflowError.invalid("two steps share an id") }
        for node in def.nodes {
            switch node.kind {
            case .tool: if (node.tool ?? "").isEmpty { throw WorkflowError.invalid("step \(node.id) has no tool") }
            case .http: if (node.args["url"] ?? "").isEmpty { throw WorkflowError.invalid("step \(node.id) has no url") }
            case .inference: if (node.prompt ?? "").isEmpty { throw WorkflowError.invalid("step \(node.id) has no prompt") }
            }
        }
        for edge in def.edges {
            guard ids.contains(edge.from), ids.contains(edge.to) else { throw WorkflowError.invalid("an edge points at a missing step") }
            if edge.from == edge.to { throw WorkflowError.invalid("step \(edge.from) feeds itself") }
        }
        // Kahn's algorithm; anything left over is in a cycle.
        var incoming = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for edge in def.edges { incoming[edge.to, default: 0] += 1 }
        var ready = def.nodes.filter { incoming[$0.id] == 0 }
        var out: [WorkflowNode] = []
        while !ready.isEmpty {
            let node = ready.removeFirst()
            out.append(node)
            for edge in def.edges where edge.from == node.id {
                incoming[edge.to, default: 0] -= 1
                if incoming[edge.to] == 0, let next = def.nodes.first(where: { $0.id == edge.to }) { ready.append(next) }
            }
        }
        guard out.count == def.nodes.count else { throw WorkflowError.invalid("the steps loop back on themselves") }
        return out
    }

    /// Tools or secrets the workflow needs that the bot does not have.
    public static func missingRequirements(_ def: WorkflowDefinition, enabledTools: [String], secretNames: [String]) -> [String] {
        let tools = Set(enabledTools).union(["web_fetch"].filter { _ in false })
        var needed = Set(def.requires.tools)
        for node in def.nodes where node.kind == .tool { if let t = node.tool { needed.insert(t) } }
        var out: [String] = []
        let off = needed.filter { !tools.contains($0) }.sorted()
        if !off.isEmpty { out.append("tools switched off: " + off.joined(separator: ", ")) }
        let have = Set(secretNames.map { $0.uppercased() })
        let secrets = def.requires.secrets.filter { !have.contains($0.uppercased()) }
        if !secrets.isEmpty { out.append("no saved secret named " + secrets.joined(separator: ", ")) }
        return out
    }
}

public enum WorkflowBindings {
    public static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        default:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    static func lookup(_ path: [String], in value: JSONValue) -> JSONValue? {
        var current = value
        for part in path {
            switch current {
            case .object(let o): guard let next = o[part] else { return nil }; current = next
            case .array(let a): guard let i = Int(part), a.indices.contains(i) else { return nil }; current = a[i]
            default: return nil
            }
        }
        return current
    }

    /// Fills `{{input.x}}` and `{{nodes.id.output.path}}` in a template. Unknown bindings become empty.
    public static func render(_ template: String, input: [String: String], outputs: [String: JSONValue]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { out += rest[open.lowerBound...]; return out }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let parts = key.split(separator: ".").map(String.init)
            if parts.first == "input", parts.count == 2 {
                out += input[parts[1]] ?? ""
            } else if parts.first == "nodes", parts.count >= 3, parts[2] == "output", let value = outputs[parts[1]] {
                out += lookup(Array(parts.dropFirst(3)), in: value).map(text) ?? ""
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

public struct WorkflowStepRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case succeeded, failed, skipped }
    public var nodeId: String
    public var status: Status
    public var attempts: Int
    public var milliseconds: Int
    public var output: JSONValue?
    public var error: String?
}

public struct WorkflowRunRecord: Codable, Sendable, Equatable {
    public var workflowId: String
    public var succeeded: Bool
    public var steps: [WorkflowStepRecord]
    public var output: [String: String]
    public var error: String?

    public var summary: String {
        var lines = ["\(succeeded ? "Finished" : "Stopped"): \(steps.filter { $0.status == .succeeded }.count)/\(steps.count) steps ok"]
        for s in steps { lines.append("- \(s.nodeId): \(s.status.rawValue)\(s.attempts > 1 ? " after \(s.attempts) tries" : "")\(s.error.map { " — \($0)" } ?? "")") }
        if let error { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}

/// Runs one step. The AppStore supplies one that goes through the bot's tools, model and approvals.
public protocol WorkflowNodeExecutor: Sendable {
    func execute(_ node: WorkflowNode, args: [String: String], prompt: String?) async throws -> JSONValue
}

public enum WorkflowRunner {
    public static func run(
        _ def: WorkflowDefinition,
        input: [String: String],
        executor: any WorkflowNodeExecutor,
        sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async -> WorkflowRunRecord {
        var record = WorkflowRunRecord(workflowId: def.id, succeeded: false, steps: [], output: [:])
        let ordered: [WorkflowNode]
        do { ordered = try WorkflowValidator.order(def) } catch { record.error = error.localizedDescription; return record }
        var values = def.defaults
        for (k, v) in input { values[k] = v }
        let missing = def.inputs.keys.filter { (values[$0] ?? "").isEmpty }.sorted()
        if !missing.isEmpty { record.error = WorkflowError.missingInput(missing).localizedDescription; return record }

        var outputs: [String: JSONValue] = [:]
        var finished: [String: WorkflowStepRecord.Status] = [:]
        var failedHard = false

        for node in ordered {
            let incoming = def.edges.filter { $0.to == node.id }
            if !incoming.isEmpty {
                let fired = incoming.map { edge -> Bool in
                    guard let status = finished[edge.from], status != .skipped else { return false }
                    switch edge.on {
                    case .success: if status != .succeeded { return false }
                    case .error: if status != .failed { return false }
                    case .always: break
                    }
                    if let when = edge.when { return when.holds(for: outputs[edge.from] ?? .null) }
                    return true
                }
                let go = node.join == .all ? fired.allSatisfy { $0 } : fired.contains(true)
                if !go {
                    finished[node.id] = .skipped
                    record.steps.append(.init(nodeId: node.id, status: .skipped, attempts: 0, milliseconds: 0, output: nil, error: nil))
                    continue
                }
            }
            if failedHard {
                finished[node.id] = .skipped
                record.steps.append(.init(nodeId: node.id, status: .skipped, attempts: 0, milliseconds: 0, output: nil, error: "an earlier step failed"))
                continue
            }
            let args = node.args.mapValues { WorkflowBindings.render($0, input: values, outputs: outputs) }
            let prompt = node.prompt.map { WorkflowBindings.render($0, input: values, outputs: outputs) }
            let started = Date()
            var attempts = 0
            var lastError: String?
            var result: JSONValue?
            while attempts < node.maxAttempts {
                attempts += 1
                do {
                    result = try await withTimeout(node.timeoutSeconds) { try await executor.execute(node, args: args, prompt: prompt) }
                    lastError = nil
                    break
                } catch {
                    lastError = error.localizedDescription
                    if attempts < node.maxAttempts { await sleep(node.backoffSeconds * Double(attempts)) }
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let result {
                outputs[node.id] = result
                finished[node.id] = .succeeded
                record.steps.append(.init(nodeId: node.id, status: .succeeded, attempts: attempts, milliseconds: ms, output: result, error: nil))
            } else {
                finished[node.id] = node.onError == .skip ? .skipped : .failed
                outputs[node.id] = .object(["error": .string(lastError ?? "failed")])
                record.steps.append(.init(nodeId: node.id, status: node.onError == .skip ? .skipped : .failed, attempts: attempts, milliseconds: ms, output: nil, error: lastError))
                if node.onError == .fail {
                    // An outgoing error edge can still handle it; otherwise the run stops here.
                    if !def.edges.contains(where: { $0.from == node.id && $0.on != .success }) { failedHard = true }
                }
            }
        }
        record.succeeded = !failedHard
        if failedHard { record.error = "A step failed and nothing handled it." }
        for (name, template) in def.output { record.output[name] = WorkflowBindings.render(template, input: values, outputs: outputs) }
        return record
    }

    private struct TimedOut: Error, LocalizedError { var errorDescription: String? { "timed out" } }

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard seconds > 0 else { return try await work() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TimedOut() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// A saved workflow is a JSON file under `workflows/` in the account folder.
public enum WorkflowLibrary {
    public static func directory(root: URL) -> URL { root.appendingPathComponent("workflows", isDirectory: true) }

    public static func load(root: URL) -> [WorkflowDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(WorkflowDefinition.self, from: $0) }
        }
    }

    public static func save(_ def: WorkflowDefinition, root: URL) throws {
        _ = try WorkflowValidator.order(def)
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(def).write(to: dir.appendingPathComponent("\(SkillMarkdown.slug(def.id)).json"), options: .atomic)
    }
}
