import AppKit
import Darwin
import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Local last-crash.txt plus optional Sentry when a DSN is configured.
enum CrashReporting {
    private static let fileName = "last-crash.txt"
    nonisolated(unsafe) private static var sentryStarted = false
    nonisolated(unsafe) private static var localSignalsInstalled = false

    static func prepare() {
        installLocalExceptionHandler()
    }

    static func install(dsn: String? = nil) {
        installLocalExceptionHandler()
        let resolved = resolvedDSN(dsn)
        if let resolved {
            startSentry(dsn: resolved)
        } else if !sentryStarted {
            installLocalSignalHandlers()
        }
    }

    static func resolvedDSN(_ preferred: String? = nil) -> String? {
        let candidates = [
            preferred,
            ProcessInfo.processInfo.environment["SENTRY_DSN"],
            Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
        ]
        for raw in candidates {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func startSentry(dsn: String?) {
        #if canImport(Sentry)
        guard !sentryStarted else { return }
        guard let dsn, !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = false
            options.swiftAsyncStacktraces = true
        }
        sentryStarted = true
        #endif
    }

    static func latestCrashText() -> String? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func fileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("GrizzyBot/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func installLocalExceptionHandler() {
        NSSetUncaughtExceptionHandler(uncaughtException)
    }

    private static func installLocalSignalHandlers() {
        guard !localSignalsInstalled else { return }
        signal(SIGABRT, crashSignal)
        signal(SIGSEGV, crashSignal)
        signal(SIGILL, crashSignal)
        signal(SIGBUS, crashSignal)
        signal(SIGFPE, crashSignal)
        localSignalsInstalled = true
    }
}

private func uncaughtException(_ exception: NSException) {
    let text = """
    \(Date())
    Name: \(exception.name.rawValue)
    Reason: \(exception.reason ?? "")
    Call stack:
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
    try? text.write(to: CrashReporting.fileURL(), atomically: true, encoding: .utf8)
}

private func crashSignal(_ code: Int32) {
    let name: String
    switch code {
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGILL: name = "SIGILL"
    case SIGBUS: name = "SIGBUS"
    case SIGFPE: name = "SIGFPE"
    default: name = "signal \(code)"
    }
    let text = "\(Date())\nFatal signal \(name)\n"
    try? text.write(to: CrashReporting.fileURL(), atomically: true, encoding: .utf8)
    signal(code, SIG_DFL)
    raise(code)
}
