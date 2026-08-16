import SwiftUI

/// Visor avatar matching rakazo `bot-avatar.tsx` geometry (HANDOFF §5.3).
struct BotAvatarView: View {
    let color: String
    var size: CGFloat = 38

    var body: some View {
        let visorWidth = size * 0.68
        let visorHeight = size * 0.40
        let visorRadius = visorHeight * 0.55
        let dot = max(3, size * 0.1)
        let gap = max(4, size * 0.13)

        ZStack {
            Circle()
                .fill(Color(hex: color))
            RoundedRectangle(cornerRadius: visorRadius, style: .continuous)
                .fill(Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255).opacity(0.78))
                .frame(width: visorWidth, height: visorHeight)
                .overlay {
                    HStack(spacing: gap) {
                        Circle().fill(Color.white).frame(width: dot, height: dot)
                        Circle().fill(Color.white).frame(width: dot, height: dot)
                    }
                }
        }
        .frame(width: size, height: size)
    }
}
