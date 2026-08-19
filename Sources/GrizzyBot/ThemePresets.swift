import Foundation

struct ThemePreset: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var author: String
    var isDark: Bool
    var colors: OsaurusThemeColors
    /// When true, applying this preset only sets appearance mode (System card).
    var isSystem: Bool

    init(
        id: String,
        name: String,
        author: String = "Osaurus",
        isDark: Bool,
        colors: OsaurusThemeColors,
        isSystem: Bool = false
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.isDark = isDark
        self.colors = colors
        self.isSystem = isSystem
    }
}

enum ThemePresets {
    static let grizzy = ThemePreset(
        id: "grizzy-default",
        name: "Grizzy",
        author: "GrizzyBot",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#DFDFE2",
            secondaryText: "#85858A",
            tertiaryText: "#6C6C70",
            primaryBackground: "#050506",
            secondaryBackground: "#0A0A0B",
            tertiaryBackground: "#17171A",
            sidebarBackground: "#0B0B0C",
            sidebarSelectedBackground: "#1A1A1D",
            accentColor: "#E65707",
            accentColorLight: "#F5A03C",
            primaryBorder: "#171719",
            secondaryBorder: "#232326",
            focusBorder: "#E65707",
            successColor: "#4ECB71",
            warningColor: "#F5A03C",
            errorColor: "#C94244",
            infoColor: "#E65707",
            cardBackground: "#17171A",
            cardBorder: "#202023",
            buttonBackground: "#121215",
            buttonBorder: "#26262A",
            inputBackground: "#131315",
            inputBorder: "#26262A",
            codeBlockBackground: "#0E0E10",
            placeholderText: "#6C6C70"
        )
    )

    static let system = ThemePreset(
        id: "system",
        name: "System",
        author: "Osaurus",
        isDark: true,
        colors: dark.colors,
        isSystem: true
    )

    static let dark = ThemePreset(
        id: "00000000-0000-0000-0000-000000000001",
        name: "Dark",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#f5f5f7",
            secondaryText: "#d1d1d6",
            tertiaryText: "#98989d",
            primaryBackground: "#1c1c1e",
            secondaryBackground: "#2c2c2e",
            tertiaryBackground: "#3a3a3c",
            sidebarBackground: "#252527",
            sidebarSelectedBackground: "#0a3d70",
            accentColor: "#0a84ff",
            accentColorLight: "#64d2ff",
            primaryBorder: "#38383a",
            secondaryBorder: "#48484a",
            focusBorder: "#0a84ff",
            successColor: "#30d158",
            warningColor: "#ff9f0a",
            errorColor: "#ff453a",
            infoColor: "#64d2ff",
            cardBackground: "#2c2c2e",
            cardBorder: "#48484a",
            buttonBackground: "#3a3a3c",
            buttonBorder: "#545458",
            inputBackground: "#2c2c2e",
            inputBorder: "#545458",
            codeBlockBackground: "#1c1c1e",
            placeholderText: "#8e8e93"
        )
    )

    static let light = ThemePreset(
        id: "00000000-0000-0000-0000-000000000002",
        name: "Light",
        isDark: false,
        colors: OsaurusThemeColors(
            primaryText: "#1d1d1f",
            secondaryText: "#515154",
            tertiaryText: "#6e6e73",
            primaryBackground: "#f5f5f7",
            secondaryBackground: "#ececf0",
            tertiaryBackground: "#f9f9fb",
            sidebarBackground: "#e9e9ed",
            sidebarSelectedBackground: "#d8e8ff",
            accentColor: "#007aff",
            accentColorLight: "#5ac8fa",
            primaryBorder: "#d1d1d6",
            secondaryBorder: "#c7c7cc",
            focusBorder: "#007aff",
            successColor: "#248a3d",
            warningColor: "#b26a00",
            errorColor: "#d70015",
            infoColor: "#007aff",
            cardBackground: "#ffffff",
            cardBorder: "#d1d1d6",
            buttonBackground: "#f6f6f7",
            buttonBorder: "#c7c7cc",
            inputBackground: "#ffffff",
            inputBorder: "#c7c7cc",
            codeBlockBackground: "#f2f2f7",
            placeholderText: "#8e8e93"
        )
    )

    static let osaurusDark = ThemePreset(
        id: "00000000-0000-0000-0000-000000000007",
        name: "Osaurus Dark",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#ffffea",
            secondaryText: "#b8c4e8",
            tertiaryText: "#98a4d0",
            primaryBackground: "#0e1120",
            secondaryBackground: "#161a2c",
            tertiaryBackground: "#1e2238",
            sidebarBackground: "#0b0e1a",
            sidebarSelectedBackground: "#1c2035",
            accentColor: "#4a6de0",
            accentColorLight: "#7090f5",
            primaryBorder: "#2a3050",
            secondaryBorder: "#3a4260",
            focusBorder: "#4a6de0",
            successColor: "#68d735",
            warningColor: "#fbbf24",
            errorColor: "#ff5b32",
            infoColor: "#4a6de0",
            cardBackground: "#161a2c",
            cardBorder: "#2a3050",
            buttonBackground: "#1e2238",
            buttonBorder: "#3a4260",
            inputBackground: "#0e1120",
            inputBorder: "#3a4260",
            codeBlockBackground: "#0b0e1a",
            placeholderText: "#7888b8"
        )
    )

    static let osaurusLight = ThemePreset(
        id: "00000000-0000-0000-0000-000000000008",
        name: "Osaurus Light",
        isDark: false,
        colors: OsaurusThemeColors(
            primaryText: "#181e38",
            secondaryText: "#3d4f7a",
            tertiaryText: "#5a6b99",
            primaryBackground: "#ffffea",
            secondaryBackground: "#f5f5d8",
            tertiaryBackground: "#ebebc8",
            sidebarBackground: "#f8f8e0",
            sidebarSelectedBackground: "#ebebce",
            accentColor: "#214099",
            accentColorLight: "#3a5ab8",
            primaryBorder: "#8890aa",
            secondaryBorder: "#b8bcd0",
            focusBorder: "#214099",
            successColor: "#2d6e10",
            warningColor: "#a16207",
            errorColor: "#d44010",
            infoColor: "#214099",
            cardBackground: "#ffffea",
            cardBorder: "#8890aa",
            buttonBackground: "#214099",
            buttonBorder: "#214099",
            inputBackground: "#ffffff",
            inputBorder: "#8890aa",
            codeBlockBackground: "#f0f0d4",
            placeholderText: "#8890aa"
        )
    )

    static let neon = ThemePreset(
        id: "00000000-0000-0000-0000-000000000003",
        name: "Neon",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#f0f0f0",
            secondaryText: "#b0b0b0",
            tertiaryText: "#909090",
            primaryBackground: "#0a0a14",
            secondaryBackground: "#12121f",
            tertiaryBackground: "#1a1a2e",
            sidebarBackground: "#0e0e1a",
            sidebarSelectedBackground: "#1f1f35",
            accentColor: "#ff00ff",
            accentColorLight: "#ff66ff",
            primaryBorder: "#3a3a55",
            secondaryBorder: "#4a4a65",
            focusBorder: "#ff00ff",
            successColor: "#00ff88",
            warningColor: "#ffcc00",
            errorColor: "#ff6688",
            infoColor: "#00ddff",
            cardBackground: "#12121f",
            cardBorder: "#3a3a55",
            buttonBackground: "#1a1a2e",
            buttonBorder: "#4a4a65",
            inputBackground: "#0e0e1a",
            inputBorder: "#3a3a55",
            codeBlockBackground: "#00000050",
            placeholderText: "#909090"
        )
    )

    static let nord = ThemePreset(
        id: "00000000-0000-0000-0000-000000000004",
        name: "Nord",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#eceff4",
            secondaryText: "#d8dee9",
            tertiaryText: "#b8c4d4",
            primaryBackground: "#2e3440",
            secondaryBackground: "#3b4252",
            tertiaryBackground: "#434c5e",
            sidebarBackground: "#2e3440",
            sidebarSelectedBackground: "#434c5e",
            accentColor: "#88c0d0",
            accentColorLight: "#8fbcbb",
            primaryBorder: "#5c667a",
            secondaryBorder: "#4c566a",
            focusBorder: "#88c0d0",
            successColor: "#a3be8c",
            warningColor: "#ebcb8b",
            errorColor: "#d08770",
            infoColor: "#88c0d0",
            cardBackground: "#3b4252",
            cardBorder: "#5c667a",
            buttonBackground: "#434c5e",
            buttonBorder: "#5c667a",
            inputBackground: "#3b4252",
            inputBorder: "#5c667a",
            codeBlockBackground: "#2e344080",
            placeholderText: "#b8c4d4"
        )
    )

    static let paper = ThemePreset(
        id: "00000000-0000-0000-0000-000000000005",
        name: "Paper",
        isDark: false,
        colors: OsaurusThemeColors(
            primaryText: "#3d3d3d",
            secondaryText: "#555555",
            tertiaryText: "#737373",
            primaryBackground: "#faf8f5",
            secondaryBackground: "#f5f2ed",
            tertiaryBackground: "#ebe7e0",
            sidebarBackground: "#f0ece5",
            sidebarSelectedBackground: "#e5e0d8",
            accentColor: "#9a7b30",
            accentColorLight: "#b8923f",
            primaryBorder: "#c5c0b8",
            secondaryBorder: "#d5d0c8",
            focusBorder: "#9a7b30",
            successColor: "#4d7c3a",
            warningColor: "#9a6a1a",
            errorColor: "#b54545",
            infoColor: "#4a7899",
            cardBackground: "#ffffff",
            cardBorder: "#c5c0b8",
            buttonBackground: "#f5f2ed",
            buttonBorder: "#a5a099",
            inputBackground: "#ffffff",
            inputBorder: "#a5a099",
            codeBlockBackground: "#f0ece520",
            placeholderText: "#737373"
        )
    )

    static let terminal = ThemePreset(
        id: "00000000-0000-0000-0000-000000000006",
        name: "Terminal",
        isDark: true,
        colors: OsaurusThemeColors(
            primaryText: "#00ff41",
            secondaryText: "#00cc33",
            tertiaryText: "#00aa2a",
            primaryBackground: "#0c0c0c",
            secondaryBackground: "#0f0f0f",
            tertiaryBackground: "#141414",
            sidebarBackground: "#0a0a0a",
            sidebarSelectedBackground: "#1a1a1a",
            accentColor: "#00ff41",
            accentColorLight: "#33ff66",
            primaryBorder: "#1a3a1a",
            secondaryBorder: "#0d1f0d",
            focusBorder: "#00ff41",
            successColor: "#00ff41",
            warningColor: "#ffb000",
            errorColor: "#ff3333",
            infoColor: "#00cc33",
            cardBackground: "#111111",
            cardBorder: "#1a3a1a",
            buttonBackground: "#0f0f0f",
            buttonBorder: "#00ff41",
            inputBackground: "#0a0a0a",
            inputBorder: "#1a3a1a",
            codeBlockBackground: "#0a0a0a",
            placeholderText: "#00aa2a"
        )
    )

    static let builtIn: [ThemePreset] = [
        system, dark, light, osaurusDark, osaurusLight, neon, nord, paper, terminal, grizzy,
    ]

    static func preset(id: String?) -> ThemePreset? {
        guard let id, !id.isEmpty else { return nil }
        return builtIn.first { $0.id == id }
    }
}
