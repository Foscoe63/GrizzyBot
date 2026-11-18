import Foundation
@testable import GrizzyBotCore
import Testing

@Suite("Run progress watchdog")
struct RunProgressTests {
    @Test("a silent run is stopped as stalled, not left to the overall cap")
    func stalls() async {
        let progress = RunProgress(modelIdleLimit: 0.2, toolSlack: 0)
        do {
            _ = try await AppStore.withRunWatchdog(seconds: 60, progress: progress, pollSeconds: 0.05) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            Issue.record("expected a stall")
        } catch {
            #expect(error is RunStalledError)
        }
    }

    @Test("activity keeps a long run alive")
    func activityResets() {
        let progress = RunProgress(modelIdleLimit: 100, toolSlack: 0)
        #expect(progress.stall(now: Date().addingTimeInterval(150)) != nil)
        progress.touch()
        #expect(progress.stall(now: Date().addingTimeInterval(50)) == nil)
    }

    @Test("a running tool gets its own limit instead of the model's")
    func toolAllowance() {
        let progress = RunProgress(modelIdleLimit: 0, toolSlack: 60)
        progress.toolStarted("shell")
        #expect(progress.stall(now: Date().addingTimeInterval(200)) == nil)
        #expect(progress.stall(now: Date().addingTimeInterval(500))?.tool == "shell")
    }

    @Test("a stopped run reports the steps it finished")
    @MainActor func reportsCompleted() {
        let progress = RunProgress()
        progress.toolStarted("import_skills")
        progress.toolFinished("import_skills", output: "Imported 15 skill(s): a, b")
        let text = AppStore.stoppedRunMessage(RunDeadlineError(seconds: 2700), progress: progress)
        #expect(text.contains("45 minutes"))
        #expect(text.contains("import_skills: Imported 15 skill(s)"))
    }
}
