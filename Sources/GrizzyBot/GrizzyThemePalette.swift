import SwiftUI

/// Osaurus-compatible color set used to build GrizzyBot surfaces.
struct OsaurusThemeColors: Sendable, Hashable {
    var primaryText: String
    var secondaryText: String
    var tertiaryText: String
    var primaryBackground: String
    var secondaryBackground: String
    var tertiaryBackground: String
    var sidebarBackground: String
    var sidebarSelectedBackground: String
    var accentColor: String
    var accentColorLight: String
    var primaryBorder: String
    var secondaryBorder: String
    var focusBorder: String
    var successColor: String
    var warningColor: String
    var errorColor: String
    var infoColor: String
    var cardBackground: String
    var cardBorder: String
    var buttonBackground: String
    var buttonBorder: String
    var inputBackground: String
    var inputBorder: String
    var codeBlockBackground: String
    var placeholderText: String?
}

/// Full GrizzyBot color palette mapped from an Osaurus theme.
struct GrizzyThemePalette: Sendable, Hashable {
    var bgApp: Color
    var bgWelcome: Color
    var bgSidebar: Color
    var bgMain: Color
    var bgRightPanel: Color
    var bgAuth: Color
    var bgAuthInput: Color
    var bgWelcomeLogo: Color
    var bgCream: Color
    var bgDarkButton: Color
    var bgDarkButtonAlt: Color
    var bgDarkButtonHover: Color
    var bgBubble: Color
    var bgCode: Color
    var bgSearch: Color
    var bgInputBar: Color
    var bgScreen: Color
    var bgCard: Color
    var bgAsk: Color
    var bgPluginsCard: Color
    var bgHostCard: Color
    var bgDeleteConfirm: Color
    var bgChip: Color
    var bgScheduleInner: Color
    var bgUserMenu: Color
    var bgLogoDark: Color
    var bgLogoBars: Color
    var bgSelectedRow: Color
    var bgHoverRow: Color
    var bgProgressTrack: Color
    var bgLetterBadge: Color
    var bgPluginLogo: Color
    var bgUserAvatar: Color

    var borderSidebar: Color
    var borderMainHdr: Color
    var borderInputsDark: Color
    var borderListRows: Color
    var borderListRowsAlt: Color
    var borderAuth: Color
    var borderAsk: Color
    var borderUserMenu: Color
    var borderDelete: Color
    var borderSearch: Color
    var borderScrollThumb: Color

    var textPrimary: Color
    var textBright: Color
    var textBrightAlt: Color
    var textSecondary: Color
    var textMuted: Color
    var textCream: Color
    var textGhost: Color
    var textPill: Color
    var textButton: Color
    var textAuthTitle: Color
    var textAuthLabel: Color
    var textAuthFooter: Color
    var textWelcomeTagline: Color
    var textSidebarIcon: Color
    var textSidebarIconHover: Color
    var textInput: Color
    var textLetter: Color
    var textSub: Color
    var textUserBubble: Color
    var textChevron: Color
    var textPluginsSub: Color

    var orange: Color
    var green: Color
    var greenAlt: Color
    var redError: Color
    var amber: Color
    var trafficRed: Color
    var trafficYellow: Color
    var trafficGreen: Color

    var isDark: Bool

    static let grizzyDefault = GrizzyThemePalette.fromOsaurus(
        ThemePresets.grizzy.colors,
        isDark: true
    )

    static func fromOsaurus(_ colors: OsaurusThemeColors, isDark: Bool) -> GrizzyThemePalette {
        func c(_ hex: String) -> Color { Color(hex: hex) }
        let primary = c(colors.primaryText)
        let secondary = c(colors.secondaryText)
        let tertiary = c(colors.tertiaryText)
        let bg0 = c(colors.primaryBackground)
        let bg1 = c(colors.secondaryBackground)
        let bg2 = c(colors.tertiaryBackground)
        let sidebar = c(colors.sidebarBackground)
        let selected = c(colors.sidebarSelectedBackground)
        let card = c(colors.cardBackground)
        let input = c(colors.inputBackground)
        let border = c(colors.primaryBorder)
        let border2 = c(colors.secondaryBorder)
        let accent = c(colors.accentColor)
        let accentLight = c(colors.accentColorLight)
        let code = c(colors.codeBlockBackground)
        let button = c(colors.buttonBackground)

        return GrizzyThemePalette(
            bgApp: bg0,
            bgWelcome: bg0,
            bgSidebar: sidebar,
            bgMain: bg0,
            bgRightPanel: bg1,
            bgAuth: isDark ? c("#F7F7F4") : c(colors.primaryBackground),
            bgAuthInput: isDark ? c("#F1F1ED") : input,
            bgWelcomeLogo: isDark ? c("#F2F2F0") : bg1,
            bgCream: isDark ? c("#F1F1EF") : c(colors.primaryBackground),
            bgDarkButton: button,
            bgDarkButtonAlt: bg2,
            bgDarkButtonHover: selected,
            bgBubble: card,
            bgCode: code,
            bgSearch: bg1,
            bgInputBar: input,
            bgScreen: code,
            bgCard: card,
            bgAsk: bg1,
            bgPluginsCard: bg1,
            bgHostCard: sidebar,
            bgDeleteConfirm: isDark ? c("#1A100C") : c(colors.errorColor).opacity(0.12),
            bgChip: bg2,
            bgScheduleInner: bg1,
            bgUserMenu: card,
            bgLogoDark: bg1,
            bgLogoBars: sidebar,
            bgSelectedRow: selected,
            bgHoverRow: bg1,
            bgProgressTrack: bg2,
            bgLetterBadge: bg2,
            bgPluginLogo: bg2,
            bgUserAvatar: bg2,
            borderSidebar: border,
            borderMainHdr: border,
            borderInputsDark: c(colors.inputBorder),
            borderListRows: border,
            borderListRowsAlt: border2,
            borderAuth: isDark ? c("#E4E4DE") : border,
            borderAsk: border2,
            borderUserMenu: border2,
            borderDelete: c(colors.errorColor).opacity(0.45),
            borderSearch: border,
            borderScrollThumb: border2,
            textPrimary: primary,
            textBright: primary,
            textBrightAlt: accentLight,
            textSecondary: secondary,
            textMuted: tertiary,
            textCream: isDark ? c("#17171A") : primary,
            textGhost: secondary,
            textPill: primary,
            textButton: isDark ? c("#FBFBF9") : c(colors.primaryBackground),
            textAuthTitle: isDark ? c("#1B1B1E") : primary,
            textAuthLabel: isDark ? c("#6E6E68") : secondary,
            textAuthFooter: isDark ? c("#8C8C86") : tertiary,
            textWelcomeTagline: primary,
            textSidebarIcon: tertiary,
            textSidebarIconHover: secondary,
            textInput: primary,
            textLetter: tertiary,
            textSub: secondary,
            textUserBubble: isDark ? c("#1A1A1A") : c(colors.primaryBackground),
            textChevron: tertiary,
            textPluginsSub: tertiary,
            orange: accent,
            green: c(colors.successColor),
            greenAlt: c(colors.successColor),
            redError: c(colors.errorColor),
            amber: c(colors.warningColor),
            trafficRed: c("#FF5F57"),
            trafficYellow: c("#FEBC2E"),
            trafficGreen: c("#28C840"),
            isDark: isDark
        )
    }
}
