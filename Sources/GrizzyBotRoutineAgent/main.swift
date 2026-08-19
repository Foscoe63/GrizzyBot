import AppKit
import Foundation
import GrizzyBotCore

let persistence = Persistence()
guard let session = persistence.loadSession() else { exit(0) }
let workspace = persistence.loadWorkspaceMerged(userId: session.userId)
let due = RoutineTickPlanner.dueRoutines(in: workspace)
guard !due.isEmpty else { exit(0) }

if hostAppIsRunning() {
    DistributedNotificationCenter.default().post(name: RoutineTickIPC.notification, object: nil)
    exit(0)
}

guard let app = hostAppBundleURL() else { exit(1) }
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
task.arguments = ["-g", "-a", app.path, "--args", LaunchArguments.tickRoutines]
do {
    try task.run()
    task.waitUntilExit()
} catch {
    fputs("GrizzyBotRoutineAgent: \(error)\n", stderr)
    exit(1)
}

func hostAppBundleURL() -> URL? {
    let agent = Bundle.main.bundleURL
    let app = agent
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    guard app.pathExtension == "app" else { return nil }
    return app
}

func hostAppIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: RoutineTickIPC.bundleId).isEmpty
}
