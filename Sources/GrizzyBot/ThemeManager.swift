import AppKit
import GrizzyBotCore
import SwiftUI

@MainActor
@Observable
final class ThemeManager {
    var appearanceMode: ThemeAppearanceMode = .dark
    var activePresetId: String = ThemePresets.grizzy.id
    private(set) var palette: GrizzyThemePalette = .grizzyDefault

    var activePreset: ThemePreset? {
        ThemePresets.preset(id: activePresetId)
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func load(from config: AppConfig) {
        appearanceMode = config.themeAppearanceMode
        activePresetId = config.activeThemePresetId ?? ThemePresets.grizzy.id
        refreshPalette(systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func snapshot(for config: inout AppConfig) {
        config.themeAppearanceMode = appearanceMode
        config.activeThemePresetId = activePresetId
    }

    func applySystemAppearance() {
        appearanceMode = .system
        activePresetId = ThemePresets.system.id
        refreshPalette(systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func applyAppearanceMode(_ mode: ThemeAppearanceMode) {
        appearanceMode = mode
        switch mode {
        case .system:
            activePresetId = ThemePresets.system.id
        case .dark:
            activePresetId = ThemePresets.dark.id
        case .light:
            activePresetId = ThemePresets.light.id
        }
        refreshPalette(systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func applyPreset(_ preset: ThemePreset) {
        if preset.isSystem {
            applySystemAppearance()
            return
        }
        activePresetId = preset.id
        if preset.id == ThemePresets.dark.id {
            appearanceMode = .dark
        } else if preset.id == ThemePresets.light.id {
            appearanceMode = .light
        } else if preset.id == ThemePresets.grizzy.id {
            appearanceMode = .dark
        }
        palette = GrizzyThemePalette.fromOsaurus(preset.colors, isDark: preset.isDark)
        ThemeBridge.palette = palette
    }

    func refreshPalette(systemDark: Bool) {
        if appearanceMode == .system {
            let preset = systemDark ? ThemePresets.dark : ThemePresets.light
            palette = GrizzyThemePalette.fromOsaurus(preset.colors, isDark: preset.isDark)
            ThemeBridge.palette = palette
            return
        }
        if let preset = ThemePresets.preset(id: activePresetId) {
            palette = GrizzyThemePalette.fromOsaurus(preset.colors, isDark: preset.isDark)
            ThemeBridge.palette = palette
            return
        }
        palette = .grizzyDefault
        ThemeBridge.palette = palette
    }

    func handleSystemAppearanceChange() {
        guard appearanceMode == .system else { return }
        refreshPalette(systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = GrizzyThemePalette.grizzyDefault
}

extension EnvironmentValues {
    var themePalette: GrizzyThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

struct ThemePaletteProvider<Content: View>: View {
    @Environment(ThemeManager.self) private var themeManager
    @ViewBuilder var content: () -> Content

    var body: some View {
        let _ = { ThemeBridge.palette = themeManager.palette }()
        content()
            .environment(\.themePalette, themeManager.palette)
            .preferredColorScheme(themeManager.preferredColorScheme)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                themeManager.handleSystemAppearanceChange()
            }
    }
}
