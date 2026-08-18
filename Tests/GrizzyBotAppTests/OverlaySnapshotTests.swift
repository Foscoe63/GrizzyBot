import AppKit
import GrizzyBotCore
import SwiftUI
import Testing
@testable import GrizzyBot

@Suite("Overlay snapshots")
@MainActor
struct OverlaySnapshotTests {
    @Test("settings overlay rasterizes")
    func settingsSnapshot() throws {
        let store = makeStore()
        store.openAppSettings()
        let image = try render(
            AppSettingsOverlayView().environment(store),
            size: CGSize(width: 900, height: 600)
        )
        try writeSnapshot(image, name: "settings-overlay")
    }

    @Test("plugins overlay rasterizes")
    func pluginsSnapshot() throws {
        let store = makeStore()
        store.pluginsOpen = true
        let image = try render(
            PluginsOverlayView().environment(store),
            size: CGSize(width: 1080, height: 760)
        )
        try writeSnapshot(image, name: "plugins-overlay")
    }

    @Test("skills overlay rasterizes")
    func skillsSnapshot() throws {
        let store = makeStore()
        store.skillsOpen = true
        let image = try render(
            SkillsOverlayView().environment(store),
            size: CGSize(width: 720, height: 640)
        )
        try writeSnapshot(image, name: "skills-overlay")
    }

    @Test("model overlay rasterizes")
    func modelSnapshot() throws {
        let store = makeStore()
        store.openModelSettings()
        let image = try render(
            ModelSettingsOverlayView().environment(store),
            size: CGSize(width: 640, height: 720)
        )
        try writeSnapshot(image, name: "model-overlay")
    }

    private func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-snap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppStore(dataDirectory: dir, delayScale: 0.01)
    }

    private func render(_ view: some View, size: CGSize) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        #expect(rep.size.width >= size.width - 1)
        #expect(rep.size.height >= size.height - 1)
        return image
    }

    private func writeSnapshot(_ image: NSImage, name: String) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw SnapshotError.noPNG
        }
        #expect(png.count > 2_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBot-Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

private enum SnapshotError: Error {
    case noBitmap
    case noPNG
}
