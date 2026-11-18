import AppKit
import GrizzyBotCore
import SwiftUI
import Testing
@testable import GrizzyBot

@Suite("Team map snapshot")
@MainActor
struct TeamMapSnapshotTests {
    @Test("team map renders its departments, cards and message box")
    func renders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gb-teammap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        let chief = store.createBot(name: "Maus", title: "Chief of Staff")
        store.setChiefOfStaff(chief.id, enabled: true)
        let ewg = store.createBot(name: "EWG", title: "Research")
        store.createDepartment("Research", botIds: [ewg.id])
        store.showTeamMapPage()

        let themeManager = ThemeManager()
        themeManager.load(from: store.appConfig)
        let size = CGSize(width: 960, height: 620)
        let host = NSHostingView(rootView: ThemePaletteProvider { TeamMapView().frame(width: size.width, height: size.height) }
            .environment(store).environment(themeManager))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 5_000)
    }
}
