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
        XCTAssertTrue(element.waitForExistence(timeout: 12), "Missing \(identifier)")
    }
}
