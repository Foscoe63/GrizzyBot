import AppKit
import CryptoKit
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

    private func makeStore() -> AppStore {
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

    private func assertGolden(_ png: Data, name: String) throws {
        let goldensRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
        let goldenURL = goldensRoot.appendingPathComponent("\(name).png")
        let hashURL = goldensRoot.appendingPathComponent("\(name).sha256")
        let refresh = ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-update-snapshots")
            || FileManager.default.fileExists(atPath: goldensRoot.appendingPathComponent(".refresh").path)

        if refresh || !FileManager.default.fileExists(atPath: goldenURL.path) {
            try FileManager.default.createDirectory(at: goldensRoot, withIntermediateDirectories: true)
            try png.write(to: goldenURL)
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            try digest.write(to: hashURL, atomically: true, encoding: .utf8)
            return
        }

        let golden = try Data(contentsOf: goldenURL)
        let actualHash = SHA256.hash(data: png)
        let goldenHash = SHA256.hash(data: golden)
        if actualHash == goldenHash { return }

        if FileManager.default.fileExists(atPath: hashURL.path),
           let expected = try? String(contentsOf: hashURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty
        {
            let actualHex = actualHash.map { String(format: "%02x", $0) }.joined()
            Issue.record("Snapshot \(name) hash mismatch (expected \(expected.prefix(12))… got \(actualHex.prefix(12))…). Set UPDATE_SNAPSHOTS=1 to refresh.")
            return
        }

        Issue.record("Snapshot \(name) differs from golden PNG. Set UPDATE_SNAPSHOTS=1 to refresh.")
    }
}

private enum SnapshotError: Error {
    case noBitmap
    case noPNG
}
