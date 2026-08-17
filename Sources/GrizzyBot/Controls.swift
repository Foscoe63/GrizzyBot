import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - GrizzyButton

enum GrizzyButtonVariant {
    case `default`
    case cream
    case outline
    case ghost
    case pill
}

enum GrizzyButtonSize {
    case sm, `default`, lg

    var height: CGFloat {
        switch self {
        case .sm: 32
        case .default: 40
        case .lg: 48
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: 12
        case .default: 16
        case .lg: 24
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .sm: 13
        case .default: 15
        case .lg: 17
        }
    }
}

struct GrizzyButton: View {
    let title: String
    var variant: GrizzyButtonVariant = .default
    var size: GrizzyButtonSize = .default
    var disabled: Bool = false
    var fullWidth: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: {
            guard !disabled else { return }
            action()
        }) {
            Text(title)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: size.height)
                .padding(.horizontal, size.horizontalPadding)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if variant == .outline {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Theme.borderInputsDark, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }

    private var cornerRadius: CGFloat {
        variant == .pill ? size.height / 2 : 13
    }

    private var foreground: Color {
        switch variant {
        case .default: Theme.textButton
        case .cream: Theme.textCream
        case .outline: Theme.textBright
        case .ghost: Theme.textGhost
        case .pill: Theme.textPill
        }
    }

    private var background: Color {
        switch variant {
        case .default:
            hovering && !disabled ? Theme.bgDarkButtonHover : Theme.bgDarkButton
        case .cream:
            Theme.bgCream
        case .outline:
            hovering && !disabled ? Color(hex: "#1A1A1D") : .clear
        case .ghost:
            .clear
        case .pill:
            hovering && !disabled ? Theme.bgDarkButtonHover : Theme.bgDarkButtonAlt
        }
    }
}

// MARK: - GrizzyField

enum GrizzyFieldStyle {
    case dark
    case auth
}

struct GrizzyField: View {
    var label: String?
    var labelSize: CGFloat = 13
    var placeholder: String
    @Binding var text: String
    var style: GrizzyFieldStyle = .dark
    var secure: Bool = false
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label)
                    .font(.system(size: style == .auth ? 16 : labelSize))
                    .foregroundStyle(style == .auth ? Theme.textAuthLabel : Theme.textSecondary)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else if let lineLimit, axis == .vertical {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(lineLimit)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: style == .auth ? 17 : 15))
            .foregroundStyle(style == .auth ? Theme.textAuthTitle : Theme.textBright)
            .textFieldStyle(.plain)
            .padding(.horizontal, style == .auth ? 18 : 14)
            .padding(.vertical, style == .auth ? 17 : 12)
            .background(style == .auth ? Theme.bgAuthInput : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: style == .auth ? 13 : 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style == .auth ? 13 : 11, style: .continuous)
                    .stroke(style == .auth ? Theme.borderAuth : Theme.borderInputsDark, lineWidth: 1)
            }
        }
    }
}

// MARK: - GrizzySelect

enum GrizzySelectStyle {
    case field
    case chip
}

struct GrizzySelect<T: Hashable & CustomStringConvertible>: View {
    let options: [T]
    @Binding var selection: T
    var style: GrizzySelectStyle = .field
    var label: ((T) -> String)? = nil

    @State private var open = false

    private func title(for value: T) -> String {
        label?(value) ?? value.description
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(title(for: selection))
                    .font(.system(size: style == .chip ? 14 : 15))
                    .foregroundStyle(Theme.textBright)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textChevron)
            }
            .padding(.horizontal, style == .chip ? 11 : 14)
            .padding(.vertical, style == .chip ? 7 : 12)
            .padding(.trailing, style == .chip ? 4 : 0)
            .background(style == .chip ? Theme.bgChip : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: style == .chip ? 8 : 11, style: .continuous))
            .overlay {
                if style == .field {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.borderInputsDark, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                            open = false
                        } label: {
                            Text(title(for: option))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textBright)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(option == selection ? Theme.bgSelectedRow : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 160, maxHeight: 260)
            .padding(6)
            .background(Theme.bgUserMenu)
        }
    }
}

// MARK: - Pulse

struct PulseModifier: ViewModifier {
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

extension View {
    func grizzyPulse() -> some View {
        modifier(PulseModifier())
    }

    func grizzyScroll() -> some View {
        self
            .scrollIndicators(.visible)
    }
}

/// Traffic-light safe zone used on dark chrome screens.
struct TrafficLightSpacer: View {
    var body: some View {
        Color.clear.frame(width: 72, height: 12)
    }
}

@MainActor
enum SessionFilePanel {
    static func save(data: Data, filename: String, utType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func saveText(_ text: String, filename: String) {
        save(data: Data(text.utf8), filename: filename, utType: .plainText)
    }

    static func openJSON() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }
}
