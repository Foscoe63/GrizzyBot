import Foundation
import GrizzyBotCore
import Testing

private struct FakeExecutor: WorkflowNodeExecutor {
    var results: [String: JSONValue] = [:]
    var failing: Set<String> = []
    let calls = Calls()
    final class Calls: @unchecked Sendable {
        var log: [String] = []; var attempts: [String: Int] = [:]; private let lock = NSLock()
        func note(_ entry: String, node: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            log.append(entry); attempts[node, default: 0] += 1
            return attempts[node]!
        }
    }

    func execute(_ node: WorkflowNode, args: [String: String], prompt: String?) async throws -> JSONValue {
        let n = calls.note("\(node.id):\(args.values.sorted().joined(separator: ","))\(prompt.map { "|\($0)" } ?? "")", node: node.id)
        if failing.contains(node.id) || (node.id == "flaky" && n < 2) { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
        return results[node.id] ?? .string("ok-\(node.id)")
    }
}

@Suite("Workflow")
struct WorkflowTests {
    let noSleep: @Sendable (Double) async -> Void = { _ in }

    @Test("a cycle, a missing edge target and an empty step are refused")
    func validation() {
        let a = WorkflowNode(id: "a", kind: .tool, tool: "x"), b = WorkflowNode(id: "b", kind: .tool, tool: "x")
        #expect(throws: WorkflowError.self) { try WorkflowValidator.order(.init(id: "w", name: "w", nodes: [a, b], edges: [.init(from: "a", to: "b"), .init(from: "b", to: "a")])) }
        #expect(throws: WorkflowError.self) { try WorkflowValidator.order(.init(id: "w", name: "w", nodes: [a], edges: [.init(from: "a", to: "zzz")])) }
        #expect(throws: WorkflowError.self) { try WorkflowValidator.order(.init(id: "w", name: "w", nodes: [WorkflowNode(id: "p", kind: .inference)])) }
        #expect(throws: Never.self) { _ = try WorkflowValidator.order(.init(id: "w", name: "w", nodes: [a, b], edges: [.init(from: "a", to: "b")])) }
    }

    @Test("bindings flow from input and earlier steps into later ones, and the output is assembled")
    func bindings() async {
        let def = WorkflowDefinition(
            id: "w", name: "w", inputs: ["topic": "what to search"],
            nodes: [
                WorkflowNode(id: "search", kind: .tool, tool: "web_search", args: ["q": "{{input.topic}}"]),
                WorkflowNode(id: "sum", kind: .inference, prompt: "Summarise {{nodes.search.output.title}}"),
            ],
            edges: [.init(from: "search", to: "sum")],
            output: ["answer": "{{nodes.sum.output}} about {{input.topic}}"]
        )
        var ex = FakeExecutor()
        ex.results = ["search": .object(["title": .string("Bears")]), "sum": .string("A summary")]
        let run = await WorkflowRunner.run(def, input: ["topic": "bears"], executor: ex, sleep: noSleep)
        #expect(run.succeeded)
        #expect(ex.calls.log == ["search:bears", "sum:|Summarise Bears"])
        #expect(run.output["answer"] == "A summary about bears")
        let missing = await WorkflowRunner.run(def, input: [:], executor: ex, sleep: noSleep)
        #expect(!missing.succeeded && missing.error?.contains("topic") == true)
    }

    @Test("conditions pick a branch and the other is skipped")
    func branching() async {
        let def = WorkflowDefinition(
            id: "w", name: "w",
            nodes: [WorkflowNode(id: "check", kind: .tool, tool: "t"), WorkflowNode(id: "yes", kind: .tool, tool: "t"), WorkflowNode(id: "no", kind: .tool, tool: "t")],
            edges: [
                .init(from: "check", to: "yes", when: .init(path: "status", op: .equals, value: "up")),
                .init(from: "check", to: "no", when: .init(path: "status", op: .notEquals, value: "up")),
            ]
        )
        var ex = FakeExecutor()
        ex.results = ["check": .object(["status": .string("up")])]
        let run = await WorkflowRunner.run(def, input: [:], executor: ex, sleep: noSleep)
        #expect(run.steps.map(\.status) == [.succeeded, .succeeded, .skipped])
    }

    @Test("retries, then onError policies: fail stops, continue and skip let the run go on")
    func errors() async {
        let retry = WorkflowDefinition(id: "w", name: "w", nodes: [WorkflowNode(id: "flaky", kind: .tool, tool: "t", maxAttempts: 3)])
        let r1 = await WorkflowRunner.run(retry, input: [:], executor: FakeExecutor(), sleep: noSleep)
        #expect(r1.succeeded && r1.steps[0].attempts == 2)

        let chain = WorkflowDefinition(
            id: "w", name: "w",
            nodes: [WorkflowNode(id: "bad", kind: .tool, tool: "t", onError: .fail), WorkflowNode(id: "after", kind: .tool, tool: "t")],
            edges: [.init(from: "bad", to: "after", on: .success)]
        )
        var ex = FakeExecutor(); ex.failing = ["bad"]
        let r2 = await WorkflowRunner.run(chain, input: [:], executor: ex, sleep: noSleep)
        #expect(!r2.succeeded && r2.steps[1].status == .skipped)

        var handled = chain
        handled.nodes[0].onError = .continue
        handled.edges[0].on = .always
        let r3 = await WorkflowRunner.run(handled, input: [:], executor: ex, sleep: noSleep)
        #expect(r3.succeeded && r3.steps[1].status == .succeeded)
    }

    @Test("an error edge handles a failure")
    func errorEdge() async {
        let def = WorkflowDefinition(
            id: "w", name: "w",
            nodes: [WorkflowNode(id: "bad", kind: .tool, tool: "t"), WorkflowNode(id: "recover", kind: .tool, tool: "t"), WorkflowNode(id: "normal", kind: .tool, tool: "t")],
            edges: [.init(from: "bad", to: "recover", on: .error), .init(from: "bad", to: "normal", on: .success)]
        )
        var ex = FakeExecutor(); ex.failing = ["bad"]
        let run = await WorkflowRunner.run(def, input: [:], executor: ex, sleep: noSleep)
        #expect(run.succeeded)
        #expect(run.steps.map(\.status) == [.failed, .succeeded, .skipped])
    }

    @Test("requirements name missing tools and secrets; a saved workflow reloads")
    func requirementsAndLibrary() throws {
        let def = WorkflowDefinition(id: "Daily Check", name: "d", nodes: [WorkflowNode(id: "a", kind: .tool, tool: "shell")], requires: .init(secrets: ["API_TOKEN"]))
        #expect(WorkflowValidator.missingRequirements(def, enabledTools: [], secretNames: []).count == 2)
        #expect(WorkflowValidator.missingRequirements(def, enabledTools: ["shell"], secretNames: ["api_token"]).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkflowLibrary.save(def, root: root)
        #expect(WorkflowLibrary.load(root: root) == [def])
    }
}
