import AppKit
import GrizzyBotCore
import SwiftUI
import Testing
@testable import GrizzyBot

@Suite("Overlay snapshots")
@MainActor
struct OverlaySnapshotTests {
    @Test("settings overlay matches golden")
    func settingsSnapshot() throws {
        let store = makeStore()
        store.openAppSettings()
        try assertGolden(
            try render(AppSettingsOverlayView(), store: store, size: CGSize(width: 900, height: 600)),
            name: "settings-overlay"
        )
    }

    @Test("plugins overlay matches golden")
    func pluginsSnapshot() throws {
        let store = makeStore()
        store.pluginsOpen = true
        try assertGolden(
            try render(PluginsOverlayView(), store: store, size: CGSize(width: 1080, height: 760)),
            name: "plugins-overlay"
        )
    }

    @Test("skills overlay matches golden")
    func skillsSnapshot() throws {
        let store = makeStore()
        store.skillsOpen = true
        try assertGolden(
            try render(SkillsOverlayView(), store: store, size: CGSize(width: 720, height: 640)),
            name: "skills-overlay"
        )
    }

    @Test("model overlay matches golden")
    func modelSnapshot() throws {
        let store = makeStore()
        store.openModelSettings()
        try assertGolden(
            try render(ModelSettingsOverlayView(), store: store, size: CGSize(width: 640, height: 720)),
            name: "model-overlay"
        )
    }

    /// Pins the one piece of real system state these overlays read, so the
    /// snapshot describes the app rather than the machine it ran on.
    private func pinEnvironment() {
        LoginItemController.statusMessageOverride = "GrizzyBot opens at login."
    }

    private func makeStore() -> AppStore {
        pinEnvironment()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-snap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
    }

    private func render(_ view: some View, store: AppStore, size: CGSize) throws -> Data {
        let themeManager = ThemeManager()
        themeManager.load(from: store.appConfig)
        let wrapped = ThemePaletteProvider {
            view
        }
        .environment(store)
        .environment(themeManager)

        let host = NSHostingView(rootView: wrapped)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.size.width >= size.width - 1)
        #expect(rep.size.height >= size.height - 1)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noPNG
        }
        #expect(png.count > 2_000)
        return png
    }

    /// Tolerances, in one place because they are the whole contract:
    ///
    /// - `downsample` averages 4×4 blocks before comparing. Anti-aliasing
    ///   differences between machines live in single edge pixels and average
    ///   out; a moved or missing element does not. Measured against six
    ///   commits of real UI change, the signal survives (0.5% → 0.5%,
    ///   10.8% → 13.7%) while the noise floor stays at 0.
    /// - `channelTolerance` ignores sub-shade colour drift.
    /// - `maxDifferingFraction` is set with ~2× margin under the smallest
    ///   genuine change ever measured here (0.49%). If CI turns out noisier,
    ///   this is the one number to raise — the failure message prints the
    ///   value it actually saw.
    private static let downsample = 4
    private static let channelTolerance = 12
    private static let maxDifferingFraction = 0.0025

    private func assertGolden(_ png: Data, name: String) throws {
        let goldensRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
        let goldenURL = goldensRoot.appendingPathComponent("\(name).png")
        let refresh = ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-update-snapshots")
            || FileManager.default.fileExists(atPath: goldensRoot.appendingPathComponent(".refresh").path)

        if refresh || !FileManager.default.fileExists(atPath: goldenURL.path) {
            try FileManager.default.createDirectory(at: goldensRoot, withIntermediateDirectories: true)
            try png.write(to: goldenURL)
            return
        }

        let golden = try Data(contentsOf: goldenURL)
        let result: SnapshotDiff.Result
        do {
            result = try SnapshotDiff.compare(
                render: png,
                golden: golden,
                name: name,
                channelTolerance: Self.channelTolerance,
                downsample: Self.downsample
            )
        } catch {
            writeActual(png, name: name)
            Issue.record("\(error)")
            return
        }

        guard result.differingFraction > Self.maxDifferingFraction else { return }

        // Leave the render on disk next to the golden: a percentage tells you
        // that something moved, not what, and CI has no other way to show you.
        let actualURL = writeActual(png, name: name)
        Issue.record(
            """
            Snapshot \(name) differs from its golden by \
            \(String(format: "%.3f", result.differingFraction * 100))% of pixels \
            (limit \(String(format: "%.3f", Self.maxDifferingFraction * 100))%, \
            largest channel delta \(result.maxChannelDelta)).
            Wrote the render to \(actualURL.path) — compare it against the golden.
            If the change is intended, re-record with UPDATE_SNAPSHOTS=1 (swift test) \
            or by creating Goldens/.refresh (xcodebuild, which does not forward the env var).
            """
        )
    }

    /// Deliberately not written into `Goldens/`: that folder is a resources
    /// path in project.yml, so a stray file there becomes a build input and
    /// the next `xcodegen generate` bakes in a reference that breaks the build
    /// the moment the file is cleaned up.
    @discardableResult
    private func writeActual(_ png: Data, name: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrizzyBotAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".snapshot-failures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(name).actual.png")
        try? png.write(to: url)
        return url
    }
}

@Suite("Chat scroll")
struct ChatScrollTests {
    @Test("follow-scroll is not a spring while the bot is working")
    func noSpringWhileWorking() {
        #expect(ChatScrollBehavior.animatesFollow(runActive: true) == false)
        #expect(ChatScrollBehavior.animatesFollow(runActive: false) == true)
        #expect(ChatScrollBehavior.shouldStick(distanceFromBottom: 10, currentlyStuck: true))
        #expect(!ChatScrollBehavior.shouldStick(distanceFromBottom: 200, currentlyStuck: true))
        #expect(!ChatScrollBehavior.shouldStick(distanceFromBottom: 80, currentlyStuck: false))
    }
}

private enum SnapshotError: Error {
    case noBitmap
    case noPNG
}
