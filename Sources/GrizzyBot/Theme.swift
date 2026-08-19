import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (a, r, g, b) = (
                255,
                (int >> 8) * 17,
                (int >> 4 & 0xF) * 17,
                (int & 0xF) * 17
            )
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// Syncs the active palette for legacy `Theme.*` accessors.
@MainActor
enum ThemeBridge {
    static var palette: GrizzyThemePalette = .grizzyDefault
}

/// Dynamic theme colors — reads the active palette from `ThemeManager`.
@MainActor
enum Theme {
    private static var p: GrizzyThemePalette { ThemeBridge.palette }

    static var bgApp: Color { p.bgApp }
    static var bgWelcome: Color { p.bgWelcome }
    static var bgSidebar: Color { p.bgSidebar }
    static var bgMain: Color { p.bgMain }
    static var bgRightPanel: Color { p.bgRightPanel }
    static var bgAuth: Color { p.bgAuth }
    static var bgAuthInput: Color { p.bgAuthInput }
    static var bgWelcomeLogo: Color { p.bgWelcomeLogo }
    static var bgCream: Color { p.bgCream }
    static var bgDarkButton: Color { p.bgDarkButton }
    static var bgDarkButtonAlt: Color { p.bgDarkButtonAlt }
    static var bgDarkButtonHover: Color { p.bgDarkButtonHover }
    static var bgBubble: Color { p.bgBubble }
    static var bgCode: Color { p.bgCode }
    static var bgSearch: Color { p.bgSearch }
    static var bgInputBar: Color { p.bgInputBar }
    static var bgScreen: Color { p.bgScreen }
    static var bgCard: Color { p.bgCard }
    static var bgAsk: Color { p.bgAsk }
    static var bgPluginsCard: Color { p.bgPluginsCard }
    static var bgHostCard: Color { p.bgHostCard }
    static var bgDeleteConfirm: Color { p.bgDeleteConfirm }
    static var bgChip: Color { p.bgChip }
    static var bgScheduleInner: Color { p.bgScheduleInner }
    static var bgUserMenu: Color { p.bgUserMenu }
    static var bgLogoDark: Color { p.bgLogoDark }
    static var bgLogoBars: Color { p.bgLogoBars }
    static var bgSelectedRow: Color { p.bgSelectedRow }
    static var bgHoverRow: Color { p.bgHoverRow }
    static var bgProgressTrack: Color { p.bgProgressTrack }
    static var bgLetterBadge: Color { p.bgLetterBadge }
    static var bgPluginLogo: Color { p.bgPluginLogo }
    static var bgUserAvatar: Color { p.bgUserAvatar }

    static var borderSidebar: Color { p.borderSidebar }
    static var borderMainHdr: Color { p.borderMainHdr }
    static var borderInputsDark: Color { p.borderInputsDark }
    static var borderListRows: Color { p.borderListRows }
    static var borderListRowsAlt: Color { p.borderListRowsAlt }
    static var borderAuth: Color { p.borderAuth }
    static var borderAsk: Color { p.borderAsk }
    static var borderUserMenu: Color { p.borderUserMenu }
    static var borderDelete: Color { p.borderDelete }
    static var borderSearch: Color { p.borderSearch }
    static var borderScrollThumb: Color { p.borderScrollThumb }

    static var textPrimary: Color { p.textPrimary }
    static var textBright: Color { p.textBright }
    static var textBrightAlt: Color { p.textBrightAlt }
    static var textSecondary: Color { p.textSecondary }
    static var textMuted: Color { p.textMuted }
    static var textCream: Color { p.textCream }
    static var textGhost: Color { p.textGhost }
    static var textPill: Color { p.textPill }
    static var textButton: Color { p.textButton }
    static var textAuthTitle: Color { p.textAuthTitle }
    static var textAuthLabel: Color { p.textAuthLabel }
    static var textAuthFooter: Color { p.textAuthFooter }
    static var textWelcomeTagline: Color { p.textWelcomeTagline }
    static var textSidebarIcon: Color { p.textSidebarIcon }
    static var textSidebarIconHover: Color { p.textSidebarIconHover }
    static var textInput: Color { p.textInput }
    static var textLetter: Color { p.textLetter }
    static var textSub: Color { p.textSub }
    static var textUserBubble: Color { p.textUserBubble }
    static var textChevron: Color { p.textChevron }
    static var textPluginsSub: Color { p.textPluginsSub }

    static var orange: Color { p.orange }
    static var green: Color { p.green }
    static var greenAlt: Color { p.greenAlt }
    static var redError: Color { p.redError }
    static var amber: Color { p.amber }
    static var trafficRed: Color { p.trafficRed }
    static var trafficYellow: Color { p.trafficYellow }
    static var trafficGreen: Color { p.trafficGreen }
}
