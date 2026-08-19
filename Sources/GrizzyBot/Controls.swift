import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

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
    var searchable: Bool = false
    var label: ((T) -> String)? = nil

    @State private var open = false
    @State private var query = ""

    private func title(for value: T) -> String {
        label?(value) ?? value.description
    }

    private var filtered: [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard searchable, !q.isEmpty else { return options }
        return options.filter { title(for: $0).lowercased().contains(q) || "\($0)".lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if searchable {
                searchableField
            } else {
                menuField
            }
        }
    }

    private var fieldLabel: some View {
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

    private var searchableField: some View {
        Button {
            open = true
        } label: {
            fieldLabel
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Choose model")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                    Spacer()
                    Button("Done") {
                        query = ""
                        open = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.orange)
                }

                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textBright)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.bgSearch)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("\(filtered.count) model\(filtered.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)

                List {
                    ForEach(filtered, id: \.self) { option in
                        Button {
                            selection = option
                            query = ""
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(title(for: option))
                                    .foregroundStyle(Theme.textBright)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)

                Button("Done") {
                    query = ""
                    open = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textCream)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.bgCream)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(16)
            .frame(minWidth: 420, minHeight: 400)
            .background(Theme.bgMain)
            .onDisappear { query = "" }
        }
    }

    private var menuField: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(for: option), systemImage: "checkmark")
                    } else {
                        Text(title(for: option))
                    }
                }
            }
        } label: {
            fieldLabel
        }
        .menuStyle(.borderlessButton)
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

/// Chat composer: Return sends, Shift-Return inserts a newline.
struct PromptComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.focusRingType = .none

        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.onSend()
        }
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 15.5)
        textView.textColor = NSColor(Theme.textInput)
        textView.insertionPointColor = NSColor(Theme.textInput)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.minSize = NSSize(width: 0, height: 22)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(in: textView)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSend = onSend
        context.coordinator.placeholder = placeholder
        guard let textView = context.coordinator.textView else { return }
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.onSend()
        }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let max = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, max), length: 0))
        }
        context.coordinator.updatePlaceholder(in: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSend: () -> Void
        var placeholder: String = ""
        weak var textView: PromptTextView?
        private var placeholderView: NSTextField?

        init(text: Binding<String>, onSend: @escaping () -> Void) {
            self.text = text
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            updatePlaceholder(in: textView)
        }

        func updatePlaceholder(in textView: NSTextView) {
            if placeholderView == nil {
                let label = NSTextField(labelWithString: placeholder)
                label.font = NSFont.systemFont(ofSize: 15.5)
                label.textColor = NSColor(Theme.textLetter)
                label.backgroundColor = .clear
                label.isBezeled = false
                label.isEditable = false
                label.isSelectable = false
                label.drawsBackground = false
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 2),
                ])
                placeholderView = label
            }
            placeholderView?.stringValue = placeholder
            placeholderView?.isHidden = !textView.string.isEmpty
        }
    }
}

final class PromptTextView: NSTextView {
    var onSend: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
            return
        }
        if ComposerKeys.shouldSend(shiftHeld: false, text: string) {
            onSend?()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 22)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = min(max(used.height + textContainerInset.height * 2, 22), 110)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
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

    static func openFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}
