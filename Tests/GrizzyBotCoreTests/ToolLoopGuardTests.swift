import Testing
@testable import GrizzyBotCore

@Suite struct ToolLoopGuardTests {
    @Test func identicalSameResultWarnsThenStops() {
        var g = ToolLoopGuard()
        var verdicts: [ToolLoopGuard.Verdict] = []
        for _ in 0..<12 {
            verdicts.append(g.record(tool: "read_file", arguments: #"{"path":"a"}"#, output: "same"))
        }
        #expect(verdicts[5] != .ok)
        if case .stop = verdicts[11] {} else { Issue.record("expected stop") }
    }

    @Test func pollingWithFreshResultsNeverTriggers() {
        var g = ToolLoopGuard()
        for i in 0..<30 {
            let v = g.record(tool: "check_status", arguments: #"{"id":"x"}"#, output: "progress \(i)%")
            if case .stop = v { Issue.record("polling should not stop") }
        }
    }

    @Test func argumentKeyOrderIsCanonical() {
        #expect(ToolLoopGuard.canonical(#"{"b":1,"a":2}"#) == ToolLoopGuard.canonical(#"{"a":2,"b":1}"#))
    }

    @Test func similarShapeStopsOnCountingArguments() {
        var g = ToolLoopGuard()
        var stopped = false
        for i in 0..<30 {
            if case .stop = g.record(tool: "web_page", arguments: #"{"page":\#(i)}"#, output: "page \(i) text") { stopped = true; break }
        }
        #expect(stopped)
    }

    @Test func exemptAndSkippedIgnored() {
        var g = ToolLoopGuard()
        for _ in 0..<40 {
            #expect(g.record(tool: "todo", arguments: "{}", output: "x") == .ok)
            #expect(g.record(tool: "read_file", arguments: "{}", output: "Skipped duplicate") == .ok)
        }
    }
}
