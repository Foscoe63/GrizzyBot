import XCTest

final class OverlayUITests: XCTestCase {
    func testSettingsOverlayIsVisible() {
        assertOverlay("settings-overlay", extraArguments: ["-uitest-open-settings"])
    }

    func testPluginsOverlayIsVisible() {
        assertOverlay("plugins-overlay", extraArguments: ["-uitest-open-plugins"])
    }

    func testSkillsOverlayIsVisible() {
        assertOverlay("skills-overlay", extraArguments: ["-uitest-open-skills"])
    }

    func testModelOverlayIsVisible() {
        assertOverlay("model-overlay", extraArguments: ["-uitest-open-model"])
    }

    private func assertOverlay(_ identifier: String, extraArguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"] + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        let element = app.descendants(matching: .any)[identifier]
        if !element.waitForExistence(timeout: 12) {
            // A failure here is usually "the app never showed a window", which the message
            // alone cannot distinguish from "the overlay did not open". Keep what the app looked like.
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "screen"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("Missing \(identifier); app has \(app.windows.count) window(s)")
        }
    }
}
