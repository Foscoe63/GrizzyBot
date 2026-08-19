import Foundation
import GrizzyBotCore
import Testing

@Suite("ThemeConfig")
struct ThemeConfigTests {
    @Test("AppConfig persists theme fields")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.themeAppearanceMode = .system
        config.activeThemePresetId = "00000000-0000-0000-0000-000000000003"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.themeAppearanceMode == .system)
        #expect(decoded.activeThemePresetId == "00000000-0000-0000-0000-000000000003")
    }

    @Test("defaults to Grizzy dark preset")
    func defaults() {
        let config = AppConfig()
        #expect(config.themeAppearanceMode == .dark)
        #expect(config.activeThemePresetId == "grizzy-default")
    }
}
