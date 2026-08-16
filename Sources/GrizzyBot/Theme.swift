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
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
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

/// Exact rakazo / GrizzyBot palette (HANDOFF §5.0).
enum Theme {
    static let bgApp = Color(hex: "#050506")
    static let bgWelcome = Color(hex: "#08080A")
    static let bgSidebar = Color(hex: "#0B0B0C")
    static let bgMain = Color(hex: "#0D0D0E")
    static let bgRightPanel = Color(hex: "#0A0A0B")
    static let bgAuth = Color(hex: "#F7F7F4")
    static let bgAuthInput = Color(hex: "#F1F1ED")
    static let bgWelcomeLogo = Color(hex: "#F2F2F0")
    static let bgCream = Color(hex: "#F1F1EF")
    static let bgDarkButton = Color(hex: "#121215")
    static let bgDarkButtonAlt = Color(hex: "#1B1B1F")
    static let bgDarkButtonHover = Color(hex: "#26262B")
    static let bgBubble = Color(hex: "#1A1A1D")
    static let bgCode = Color(hex: "#0E0E10")
    static let bgSearch = Color(hex: "#141416")
    static let bgInputBar = Color(hex: "#131315")
    static let bgScreen = Color(hex: "#0E0E10")
    static let bgCard = Color(hex: "#17171A")
    static let bgAsk = Color(hex: "#141417")
    static let bgPluginsCard = Color(hex: "#141416")
    static let bgHostCard = Color(hex: "#121214")
    static let bgDeleteConfirm = Color(hex: "#1A100C")
    static let bgChip = Color(hex: "#24242A")
    static let bgScheduleInner = Color(hex: "#16161A")
    static let bgUserMenu = Color(hex: "#1A1A1D")
    static let bgLogoDark = Color(hex: "#16161A")
    static let bgLogoBars = Color(hex: "#101012")
    static let bgSelectedRow = Color(hex: "#1A1A1D")
    static let bgHoverRow = Color(hex: "#161618")
    static let bgProgressTrack = Color(hex: "#232327")
    static let bgLetterBadge = Color(hex: "#232327")
    static let bgPluginLogo = Color(hex: "#2C2C30")
    static let bgUserAvatar = Color(hex: "#232326")

    static let borderSidebar = Color(hex: "#171719")
    static let borderMainHdr = Color(hex: "#141416")
    static let borderInputsDark = Color(hex: "#26262A")
    static let borderListRows = Color(hex: "#202023")
    static let borderListRowsAlt = Color(hex: "#232326")
    static let borderAuth = Color(hex: "#E4E4DE")
    static let borderAsk = Color(hex: "#242428")
    static let borderUserMenu = Color(hex: "#2A2A2F")
    static let borderDelete = Color(hex: "#3A1F14")
    static let borderSearch = Color(hex: "#202023")
    static let borderScrollThumb = Color(hex: "#2A2A2E")

    static let textPrimary = Color(hex: "#DFDFE2")
    static let textBright = Color(hex: "#ECECEE")
    static let textBrightAlt = Color(hex: "#F1F1F2")
    static let textSecondary = Color(hex: "#85858A")
    static let textMuted = Color(hex: "#6C6C70")
    static let textCream = Color(hex: "#17171A")
    static let textGhost = Color(hex: "#C9C9CE")
    static let textPill = Color(hex: "#F2F2F3")
    static let textButton = Color(hex: "#FBFBF9")
    static let textAuthTitle = Color(hex: "#1B1B1E")
    static let textAuthLabel = Color(hex: "#6E6E68")
    static let textAuthFooter = Color(hex: "#8C8C86")
    static let textWelcomeTagline = Color(hex: "#E4E4E6")
    static let textSidebarIcon = Color(hex: "#7A7A80")
    static let textSidebarIconHover = Color(hex: "#C9C9CE")
    static let textInput = Color(hex: "#E9E9EA")
    static let textLetter = Color(hex: "#9A9AA0")
    static let textSub = Color(hex: "#A8A8AD")
    static let textUserBubble = Color(hex: "#1A1A1A")
    static let textChevron = Color(hex: "#9A9AA0")
    static let textPluginsSub = Color(hex: "#7A7A80")

    static let orange = Color(hex: "#E65707")
    static let green = Color(hex: "#4ECB71")
    static let greenAlt = Color(hex: "#30A24B")
    static let redError = Color(hex: "#C94244")
    static let amber = Color(hex: "#F5A03C")
    static let trafficRed = Color(hex: "#FF5F57")
    static let trafficYellow = Color(hex: "#FEBC2E")
    static let trafficGreen = Color(hex: "#28C840")
}
