import AppKit
import GrizzyBotCore
import SwiftUI

/// Colours for each token kind, keyed off the panel's light/dark appearance.
///
/// Deliberately its own type rather than scattered literals: the read-only
/// Source view and the editor have to agree, or toggling Edit would recolour
/// the text under you.
enum SyntaxPalette {
    static func color(_ token: SyntaxToken, dark: Bool) -> NSColor {
        switch token {
        case .plain:
            return dark ? NSColor(hex: "#E6E3DF") : NSColor(hex: "#1F1F22")
        case .keyword:
            return dark ? NSColor(hex: "#FF9E64") : NSColor(hex: "#B4531A")
        case .type:
            return dark ? NSColor(hex: "#7FD4C1") : NSColor(hex: "#1D7A66")
        case .string:
            return dark ? NSColor(hex: "#9ECE6A") : NSColor(hex: "#3F7A1E")
        case .comment:
            return dark ? NSColor(hex: "#6B7280") : NSColor(hex: "#8A8F98")
        case .number:
            return dark ? NSColor(hex: "#D3A0F0") : NSColor(hex: "#7A3DA6")
        case .tag:
            return dark ? NSColor(hex: "#7AA2F7") : NSColor(hex: "#2A5DB0")
        case .attribute:
            return dark ? NSColor(hex: "#E0AF68") : NSColor(hex: "#8A6414")
        case .punctuation:
            return dark ? NSColor(hex: "#9AA0AA") : NSColor(hex: "#6A6F78")
        }
    }

    /// Computed rather than stored: `NSFont` is not Sendable, so a static
    /// constant is a concurrency error under strict checking.
    static var font: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    /// Applies spans over a base attributed string. Shared by the editor and
    /// the read-only view so both render identically.
    static func attributed(_ source: String, language: SyntaxLanguage, dark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: color(.plain, dark: dark),
            ]
        )
        let limit = result.length
        for span in SyntaxHighlighter.spans(source, language: language) {
            let range = NSRange(location: span.location, length: span.length)
            guard range.location >= 0, NSMaxRange(range) <= limit else { continue }
            result.addAttribute(.foregroundColor, value: color(span.token, dark: dark), range: range)
        }
        return result
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Line numbers

/// A gutter for the editor. `NSTextView` has no built-in line ruler, and
/// without one a compile error that names a line number is unusable.
final class LineNumberRuler: NSRulerView {
    private let dark: Bool

    init(textView: NSTextView, dark: Bool) {
        self.dark = dark
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Count the lines before the visible range once, then walk forward.
        var line = 1
        for index in 0..<characterRange.location where text.character(at: index) == 10 {
            line += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: dark ? NSColor(hex: "#5A6069") : NSColor(hex: "#9AA0AA"),
        ]

        var index = characterRange.location
        let end = NSMaxRange(characterRange)
        while index <= end {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyph, in: container)
            lineRect.origin.y += textView.textContainerInset.height - visible.origin.y

            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 7, y: lineRect.origin.y + 1),
                withAttributes: attributes
            )

            line += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
    }
}

// MARK: - Editor

/// A syntax-highlighted text editor.
///
/// Built on `NSTextView` rather than SwiftUI's `TextEditor`, which cannot
/// colour its own text, and rather than embedding a JavaScript editor, which
/// would mean vendoring another runtime and opening a script bridge into the
/// app for what is ultimately attributed-string work.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: SyntaxLanguage
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        /// Guards against the round trip where our own programmatic update
        /// re-enters as an edit and moves the caret.
        var applying = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            rehighlight(textView)
        }

        /// Re-colours in place, preserving the selection — replacing the whole
        /// storage would send the caret to the start on every keystroke.
        func rehighlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string
            let full = NSRange(location: 0, length: (source as NSString).length)

            storage.beginEditing()
            storage.addAttribute(.font, value: SyntaxPalette.font, range: full)
            storage.addAttribute(
                .foregroundColor,
                value: SyntaxPalette.color(.plain, dark: parent.dark),
                range: full
            )
            for span in SyntaxHighlighter.spans(source, language: parent.language) {
                let range = NSRange(location: span.location, length: span.length)
                guard range.location >= 0, NSMaxRange(range) <= full.length else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: SyntaxPalette.color(span.token, dark: parent.dark),
                    range: range
                )
            }
            storage.endEditing()
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = SyntaxPalette.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = dark ? NSColor(hex: "#141416") : NSColor(hex: "#FBFAF8")
        textView.insertionPointColor = SyntaxPalette.color(.plain, dark: dark)
        textView.string = text

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let ruler = LineNumberRuler(textView: textView, dark: dark)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.rehighlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        guard textView.string != text else { return }
        // An external change (a bot rewrote the artifact, or the draft was
        // reset): replace the text, then restore the caret if it still fits.
        context.coordinator.applying = true
        let selected = textView.selectedRange()
        textView.string = text
        let limit = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
        context.coordinator.rehighlight(textView)
        context.coordinator.applying = false
        scroll.verticalRulerView?.needsDisplay = true
    }
}

// MARK: - Read-only source

/// The Source view, coloured the same way so toggling Edit does not restyle.
struct HighlightedSourceView: NSViewRepresentable {
    let text: String
    let language: SyntaxLanguage
    let dark: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.textStorage?.setAttributedString(
            SyntaxPalette.attributed(text, language: language, dark: dark)
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(
            SyntaxPalette.attributed(text, language: language, dark: dark)
        )
    }
}
