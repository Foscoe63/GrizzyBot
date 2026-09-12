import AppKit
import GrizzyBotCore
import SwiftUI
import Testing
@testable import GrizzyBot

@Suite("Code editor")
@MainActor
struct CodeEditorTests {
    private let sample = """
        // a comment
        let count: Int = 42
        let name = "Ada"
        """

    @Test("Attributing colours each token kind differently from plain text")
    func attributesDifferByToken() throws {
        let attributed = SyntaxPalette.attributed(sample, language: .swift, dark: true)
        let text = sample as NSString

        func colour(of needle: String) -> NSColor? {
            let range = text.range(of: needle)
            guard range.location != NSNotFound else { return nil }
            return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }

        let plain = SyntaxPalette.color(.plain, dark: true)
        #expect(colour(of: "// a comment") == SyntaxPalette.color(.comment, dark: true))
        #expect(colour(of: "let") == SyntaxPalette.color(.keyword, dark: true))
        #expect(colour(of: "Int") == SyntaxPalette.color(.type, dark: true))
        #expect(colour(of: "42") == SyntaxPalette.color(.number, dark: true))
        #expect(colour(of: "\"Ada\"") == SyntaxPalette.color(.string, dark: true))
        #expect(colour(of: "count") == plain)
    }

    @Test("Every token kind has its own colour, in light and dark")
    func paletteIsDistinct() {
        for dark in [true, false] {
            var seen: [String: SyntaxToken] = [:]
            for token in SyntaxToken.allCases {
                let key = SyntaxPalette.color(token, dark: dark).description
                #expect(seen[key] == nil, "\(token) shares a colour with \(seen[key]!) (dark: \(dark))")
                seen[key] = token
            }
        }
    }

    /// Counts distinct *hue families* among saturated pixels. Plain monochrome
    /// text still yields many RGB values through anti-aliasing, so counting
    /// colours alone would pass even with highlighting switched off — the
    /// thing this test exists to catch.
    private func hueFamilies(_ view: some View, size: CGSize) throws -> Set<Int> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var families = Set<Int>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Ignore greys: background, plain text, and anti-aliasing.
                guard colour.saturationComponent > 0.25, colour.brightnessComponent > 0.2 else { continue }
                families.insert(Int(colour.hueComponent * 12))
            }
        }
        return families
    }

    @Test("Highlighting puts distinctly more colour on screen than plain text does")
    func editorRendersColours() throws {
        let size = CGSize(width: 460, height: 170)
        let highlighted = try hueFamilies(
            CodeEditorView(text: .constant(sample), language: .swift, dark: true),
            size: size
        )
        // The same text with no grammar: the control.
        let plain = try hueFamilies(
            CodeEditorView(text: .constant(sample), language: .plain, dark: true),
            size: size
        )

        #expect(plain.count <= 1, "unhighlighted text should be monochrome, saw \(plain.count) hue families")
        #expect(
            highlighted.count >= 3,
            "highlighting produced only \(highlighted.count) hue families — it is not reaching the screen"
        )
        #expect(highlighted.count > plain.count)
    }

    @Test("The read-only source view renders too")
    func sourceViewRenders() throws {
        let view = HighlightedSourceView(text: sample, language: .swift, dark: true)
        let host = NSHostingView(rootView: view.frame(width: 420, height: 160))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
    }

    @Test("Every artifact kind resolves to a grammar the editor can use")
    func everyKindHasAGrammar() {
        for kind in ArtifactKind.allCases {
            let language = SyntaxLanguage.of(kind: kind, language: kind == .code ? "swift" : nil)
            let attributed = SyntaxPalette.attributed(kind.starterContent, language: language, dark: true)
            #expect(attributed.length == (kind.starterContent as NSString).length)
        }
    }
}
