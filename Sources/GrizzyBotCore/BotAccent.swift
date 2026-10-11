import Foundation

/// Picks readable text for a bot-coloured bubble.
public enum BotAccent {
    /// Parses `#RRGGBB` / `RRGGBB`. Nil for anything else.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    public static func luminance(_ hex: String) -> Double? {
        guard let c = rgb(hex) else { return nil }
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// True when white text reads better than black on this colour.
    public static func prefersLightText(onHex hex: String) -> Bool {
        guard let l = luminance(hex) else { return false }
        // Contrast with white is 1.05 / (l + 0.05); with black it is (l + 0.05) / 0.05.
        return 1.05 / (l + 0.05) >= (l + 0.05) / 0.05
    }
}
