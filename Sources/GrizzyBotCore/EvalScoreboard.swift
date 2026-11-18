import Foundation

/// One scored case in an eval suite.
public struct EvalCaseResult: Codable, Sendable, Equatable {
    public var suite: String
    public var id: String
    public var passed: Bool
    public var detail: String
    public init(suite: String, id: String, passed: Bool, detail: String = "") {
        self.suite = suite
        self.id = id
        self.passed = passed
        self.detail = detail
    }
}

/// Pass-rate floors: a suite below its floor, or a named case that fails, fails the gate.
public struct EvalFloors: Codable, Sendable, Equatable {
    public var suites: [String: Double]
    /// Cases that must always pass, as `suite/id`.
    public var mustPass: [String]
    public init(suites: [String: Double] = [:], mustPass: [String] = []) {
        self.suites = suites
        self.mustPass = mustPass
    }

    public static func load(_ url: URL) -> EvalFloors? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EvalFloors.self, from: data)
    }
}

public struct EvalReport: Codable, Sendable, Equatable {
    public var results: [EvalCaseResult]
    public init(results: [EvalCaseResult] = []) { self.results = results }

    public var suites: [String] { Array(Set(results.map(\.suite))).sorted() }

    public func passRate(suite: String) -> Double {
        let rows = results.filter { $0.suite == suite }
        guard !rows.isEmpty else { return 0 }
        return Double(rows.filter(\.passed).count) / Double(rows.count)
    }

    /// Human-readable reasons the report misses its floors. Empty means the gate passes.
    public func violations(against floors: EvalFloors) -> [String] {
        var out: [String] = []
        for (suite, floor) in floors.suites.sorted(by: { $0.key < $1.key }) {
            guard results.contains(where: { $0.suite == suite }) else {
                out.append("suite \(suite) has no cases")
                continue
            }
            let rate = passRate(suite: suite)
            if rate + 1e-9 < floor {
                out.append("suite \(suite) pass rate \(Self.percent(rate)) is under its floor \(Self.percent(floor))")
            }
        }
        for key in floors.mustPass {
            guard let row = results.first(where: { "\($0.suite)/\($0.id)" == key }) else {
                out.append("required case \(key) did not run")
                continue
            }
            if !row.passed { out.append("required case \(key) failed: \(row.detail)") }
        }
        return out
    }

    /// Cases whose outcome changed from a previous report.
    public func diff(from previous: EvalReport) -> (regressions: [String], fixes: [String]) {
        var old: [String: Bool] = [:]
        for r in previous.results { old["\(r.suite)/\(r.id)"] = r.passed }
        var regressions: [String] = []
        var fixes: [String] = []
        for r in results {
            let key = "\(r.suite)/\(r.id)"
            guard let was = old[key] else { continue }
            if was && !r.passed { regressions.append(key) }
            if !was && r.passed { fixes.append(key) }
        }
        return (regressions.sorted(), fixes.sorted())
    }

    public func markdown() -> String {
        var lines = ["# Eval report", "", "| suite | cases | pass rate |", "|---|---|---|"]
        for suite in suites {
            lines.append("| \(suite) | \(results.filter { $0.suite == suite }.count) | \(Self.percent(passRate(suite: suite))) |")
        }
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            lines += ["", "## Failures"]
            lines += failed.map { "- \($0.suite)/\($0.id): \($0.detail)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// A judge grades a model answer against a rubric. Calibration runs it over fixtures with known
/// verdicts, so a judge that drifts is caught before it grades anything real.
public protocol EvalJudge: Sendable {
    func verdict(question: String, answer: String, rubric: String) -> Bool
}

public struct JudgeCalibrationCase: Codable, Sendable, Equatable {
    public var id: String
    public var question: String
    public var answer: String
    public var rubric: String
    public var expected: Bool
    public init(id: String, question: String, answer: String, rubric: String, expected: Bool) {
        self.id = id
        self.question = question
        self.answer = answer
        self.rubric = rubric
        self.expected = expected
    }
}

public enum JudgeCalibration {
    /// Accuracy of a judge over known-verdict cases, as per-case results in the `judge-calibration` suite.
    public static func run(judge: some EvalJudge, cases: [JudgeCalibrationCase]) -> [EvalCaseResult] {
        cases.map { c in
            let got = judge.verdict(question: c.question, answer: c.answer, rubric: c.rubric)
            return EvalCaseResult(
                suite: "judge-calibration",
                id: c.id,
                passed: got == c.expected,
                detail: got == c.expected ? "" : "judge said \(got), expected \(c.expected)"
            )
        }
    }
}

/// A rubric judge that needs no model: an answer passes when it holds every `must:` phrase and none of
/// the `never:` phrases. It is the scripted lane's stand-in for an LLM judge.
public struct KeywordJudge: EvalJudge {
    public init() {}
    public func verdict(question: String, answer: String, rubric: String) -> Bool {
        let lowered = answer.lowercased()
        for rawLine in rubric.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("must:"), !lowered.contains(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) { return false }
            if line.hasPrefix("never:"), lowered.contains(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) { return false }
        }
        return true
    }
}
