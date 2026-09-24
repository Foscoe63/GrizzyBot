import AppKit
import GrizzyBotCore
import SwiftUI

/// Bot avatar: a body shape in the bot's colour with the visor face on top
/// (HANDOFF §5.3), or an uploaded picture clipped to the same shape.
struct BotAvatarView: View {
    let bot: Bot
    var size: CGFloat = 38
    @Environment(AppStore.self) private var store

    var body: some View {
        let shape = AvatarBodyShape(BotAvatarShape.resolve(bot.avatarShape))
        ZStack {
            if let image = AvatarImageCache.image(for: bot, url: store.avatarImageURL(for: bot)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                shape.fill(Color(hex: bot.color))
                visor
                    .scaleEffect(visorScale(for: BotAvatarShape.resolve(bot.avatarShape)))
                    .offset(y: bot.avatarShape == BotAvatarShape.triangle.rawValue ? size * 0.12 : 0)
            }
        }
        .frame(width: size, height: size)
    }

    /// Pointed shapes have less room at the sides than a circle does.
    private func visorScale(for shape: BotAvatarShape) -> CGFloat {
        switch shape {
        case .triangle: return 0.62
        case .diamond: return 0.72
        case .hexagon: return 0.88
        case .circle, .squircle, .pill: return 1
        }
    }

    private var visor: some View {
        let visorHeight = size * 0.40
        let dot = max(3, size * 0.1)
        let gap = max(4, size * 0.13)
        return RoundedRectangle(cornerRadius: visorHeight * 0.55, style: .continuous)
            .fill(Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255).opacity(0.78))
            .frame(width: size * 0.68, height: visorHeight)
            .overlay {
                HStack(spacing: gap) {
                    Circle().fill(Color.white).frame(width: dot, height: dot)
                    Circle().fill(Color.white).frame(width: dot, height: dot)
                }
            }
    }
}

/// Path for each `BotAvatarShape`, inscribed in the square it is given.
struct AvatarBodyShape: Shape {
    let kind: BotAvatarShape

    init(_ kind: BotAvatarShape) { self.kind = kind }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let r = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        switch kind {
        case .circle:
            return Path(ellipseIn: r)
        case .squircle:
            return RoundedRectangle(cornerRadius: s * 0.32, style: .continuous).path(in: r)
        case .pill:
            let h = s * 0.78
            let pill = CGRect(x: r.minX, y: r.midY - h / 2, width: s, height: h)
            return RoundedRectangle(cornerRadius: h / 2, style: .continuous).path(in: pill)
        case .hexagon:
            return polygon(r, sides: 6, rotation: .pi / 2)
        case .triangle:
            return polygon(r, sides: 3, rotation: -.pi / 2, inset: 0.92)
        case .diamond:
            return polygon(r, sides: 4, rotation: -.pi / 2)
        }
    }

    private func polygon(_ r: CGRect, sides: Int, rotation: Double, inset: Double = 1) -> Path {
        let radius = r.width / 2 * inset
        var path = Path()
        for i in 0..<sides {
            let angle = rotation + Double(i) * 2 * .pi / Double(sides)
            let p = CGPoint(x: r.midX + radius * cos(angle), y: r.midY + radius * sin(angle))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

/// Decoded avatars keyed by bot and revision, so list rows don't hit disk on every render.
@MainActor
enum AvatarImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for bot: Bot, url: URL?) -> NSImage? {
        guard let rev = bot.avatarImageRev, let url else { return nil }
        let key = "\(bot.id)-\(rev)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Centre-crops to a square and scales to `edge` px, returning PNG data.
    static func normalizedPNG(from url: URL, edge: Int = 256) -> Data? {
        guard let source = NSImage(contentsOf: url),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let side = min(source.size.width, source.size.height)
        guard side > 0 else { return nil }
        let crop = NSRect(
            x: (source.size.width - side) / 2, y: (source.size.height - side) / 2,
            width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
