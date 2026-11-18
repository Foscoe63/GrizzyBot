import Foundation
import GrizzyBotCore
import Testing

/// Drop-in JSON suites under `Evals/Suites`, scored without a model, then held to `Evals/floors.json`.
/// A suite below its floor fails the build. Reports land in `Evals/reports/` (gitignored).
@Suite("Eval floors")
struct EvalFloorTests {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Evals")

    static func cases(_ suite: String) -> [[String: Any]] {
        let url = root.appendingPathComponent("Suites/\(suite).json")
        guard let data = try? Data(contentsOf: url),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array
    }

    static func run() -> EvalReport {
        var results: [EvalCaseResult] = []
        for c in cases("prompt-injection") {
            let flagged = !UntrustedContent.suspicion(in: c["text"] as? String ?? "").isEmpty
            let want = c["flagged"] as? Bool ?? false
            results.append(.init(suite: "prompt-injection", id: c["id"] as? String ?? "?", passed: flagged == want, detail: "flagged=\(flagged)"))
        }
        for c in cases("secret-leak") {
            let found = !LeakScanner.findings(in: c["text"] as? String ?? "").isEmpty
            let want = c["leaks"] as? Bool ?? false
            results.append(.init(suite: "secret-leak", id: c["id"] as? String ?? "?", passed: found == want, detail: "found=\(found)"))
        }
        for c in cases("memory-recall") {
            let got = MemoryRelevanceGate.decide(query: c["query"] as? String ?? "").rawValue
            let want = c["section"] as? String ?? ""
            results.append(.init(suite: "memory-recall", id: c["id"] as? String ?? "?", passed: got == want, detail: "got \(got)"))
        }
        for c in cases("tool-envelope") {
            let got = ToolEnvelope.classify(output: c["output"] as? String ?? "")?.kind.rawValue
            let want = c["kind"] as? String
            results.append(.init(suite: "tool-envelope", id: c["id"] as? String ?? "?", passed: got == want, detail: "got \(got ?? "none")"))
        }
        let calibration = cases("judge-calibration").map {
            JudgeCalibrationCase(
                id: $0["id"] as? String ?? "?", question: $0["question"] as? String ?? "",
                answer: $0["answer"] as? String ?? "", rubric: $0["rubric"] as? String ?? "",
                expected: $0["expected"] as? Bool ?? false
            )
        }
        results += JudgeCalibration.run(judge: KeywordJudge(), cases: calibration)
        return EvalReport(results: results)
    }

    @Test("every suite meets its floor")
    func floors() throws {
        let report = Self.run()
        let floors = try #require(EvalFloors.load(Self.root.appendingPathComponent("floors.json")))
        // Keep the latest report, and tell the author what regressed since the last one.
        let latest = Self.root.appendingPathComponent("reports/latest.json")
        if let data = try? Data(contentsOf: latest), let previous = try? JSONDecoder().decode(EvalReport.self, from: data) {
            let diff = report.diff(from: previous)
            #expect(diff.regressions.isEmpty, "regressed since last run: \(diff.regressions)")
        }
        try? FileManager.default.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(report).write(to: latest)
        try? report.markdown().write(to: latest.deletingLastPathComponent().appendingPathComponent("latest.md"), atomically: true, encoding: .utf8)
        #expect(report.violations(against: floors).isEmpty, "\(report.violations(against: floors))")
    }

    @Test("a failing suite trips the gate, and a regression shows in the diff")
    func gateTrips() {
        let good = EvalReport(results: [.init(suite: "s", id: "a", passed: true), .init(suite: "s", id: "b", passed: true)])
        let bad = EvalReport(results: [.init(suite: "s", id: "a", passed: true), .init(suite: "s", id: "b", passed: false, detail: "x")])
        let floors = EvalFloors(suites: ["s": 1.0], mustPass: ["s/b"])
        #expect(good.violations(against: floors).isEmpty)
        #expect(bad.violations(against: floors).count == 2)
        #expect(bad.diff(from: good).regressions == ["s/b"])
    }

    @Test("a judge that gets known verdicts wrong fails calibration")
    func judgeDrift() {
        struct Yes: EvalJudge { func verdict(question: String, answer: String, rubric: String) -> Bool { true } }
        let cases = [JudgeCalibrationCase(id: "x", question: "", answer: "no", rubric: "must: yes", expected: false)]
        #expect(JudgeCalibration.run(judge: Yes(), cases: cases).allSatisfy { !$0.passed })
        #expect(JudgeCalibration.run(judge: KeywordJudge(), cases: cases).allSatisfy { $0.passed })
    }
}
