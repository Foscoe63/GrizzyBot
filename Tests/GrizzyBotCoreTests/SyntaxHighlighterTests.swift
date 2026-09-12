import Foundation
import Testing
@testable import GrizzyBotCore

/// Helpers that describe spans by the text they cover, so the expectations read
/// as "this word is a keyword" rather than as offset arithmetic.
private extension String {
    func slice(_ span: SyntaxSpan) -> String {
        let text = self as NSString
        guard span.location >= 0, span.location + span.length <= text.length else { return "" }
        return text.substring(with: NSRange(location: span.location, length: span.length))
    }
}

private func tokens(_ source: String, _ language: SyntaxLanguage) -> [(String, SyntaxToken)] {
    SyntaxHighlighter.spans(source, language: language).map { (source.slice($0), $0.token) }
}

private func token(_ source: String, _ language: SyntaxLanguage, for text: String) -> SyntaxToken? {
    tokens(source, language).first { $0.0 == text }?.1
}

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    @Test("Keywords, types, strings and numbers are told apart in Swift")
    func swiftBasics() {
        let source = "let count: Int = 42 // note\nlet name = \"Ada\""
        #expect(token(source, .swift, for: "let") == .keyword)
        #expect(token(source, .swift, for: "Int") == .type)
        #expect(token(source, .swift, for: "42") == .number)
        #expect(token(source, .swift, for: "\"Ada\"") == .string)
        #expect(token(source, .swift, for: "// note") == .comment)
    }

    @Test("A comment marker inside a string is not a comment")
    func commentMarkerInsideString() {
        let source = "let url = \"https://example.com\" // real comment"
        let spans = tokens(source, .swift)
        #expect(spans.contains { $0 == ("\"https://example.com\"", .string) })
        #expect(spans.contains { $0 == ("// real comment", .comment) })
        // The // inside the URL must not have started a comment.
        #expect(!spans.contains { $0.0.contains("example.com") && $0.1 == .comment })
    }

    @Test("A quote inside a comment does not open a string")
    func quoteInsideComment() {
        let source = "// it's fine\nlet x = 1"
        let spans = tokens(source, .swift)
        #expect(spans.contains { $0 == ("// it's fine", .comment) })
        #expect(spans.contains { $0 == ("let", .keyword) })
        #expect(!spans.contains { $0.1 == .string })
    }

    @Test("Escaped quotes do not end a string early")
    func escapedQuote() {
        let source = "let s = \"a\\\"b\" + x"
        #expect(token(source, .swift, for: "\"a\\\"b\"") == .string)
    }

    @Test("An unterminated string stops at the line, not the end of the file")
    func unterminatedString() {
        let source = "let a = \"oops\nlet b = 2"
        let spans = SyntaxHighlighter.spans(source, language: .swift)
        let strings = spans.filter { $0.token == .string }
        #expect(strings.count == 1)
        #expect(!source.slice(strings[0]).contains("let b"))
        // The next line still highlights normally.
        #expect(token(source, .swift, for: "let") == .keyword)
    }

    @Test("JSX picks up components, keywords and template literals")
    func jsxBasics() {
        let source = "import React from 'react';\nexport default function App() { return <div/>; }"
        #expect(token(source, .javascript, for: "import") == .keyword)
        #expect(token(source, .javascript, for: "'react'") == .string)
        #expect(token(source, .javascript, for: "React") == .type)
        #expect(token(source, .javascript, for: "export") == .keyword)
    }

    @Test("Markup separates tags, attributes and attribute values")
    func markupBasics() {
        let source = "<div class=\"p-4\" id='x'>hi</div>"
        let spans = tokens(source, .markup)
        #expect(spans.contains { $0 == ("<div", .tag) })
        #expect(spans.contains { $0 == ("class", .attribute) })
        #expect(spans.contains { $0 == ("\"p-4\"", .string) })
        #expect(spans.contains { $0 == ("'x'", .string) })
        #expect(spans.contains { $0 == ("</div", .tag) })
    }

    @Test("An HTML comment is a comment, tags inside it included")
    func markupComment() {
        let source = "<!-- <div> hidden --><p>shown</p>"
        let spans = tokens(source, .markup)
        #expect(spans.contains { $0 == ("<!-- <div> hidden -->", .comment) })
        #expect(spans.contains { $0 == ("<p", .tag) })
    }

    @Test("Python treats # as a comment and knows its own keywords")
    func pythonBasics() {
        let source = "def go(): # start\n    return None"
        #expect(token(source, .python, for: "def") == .keyword)
        #expect(token(source, .python, for: "# start") == .comment)
        #expect(token(source, .python, for: "None") == .keyword)
    }

    @Test("Markdown marks headings and fenced code")
    func markdownBasics() {
        let source = "# Title\n\ntext\n\n```\ncode\n```\n"
        let spans = tokens(source, .markdown)
        #expect(spans.contains { $0 == ("# Title", .keyword) })
        #expect(spans.contains { $0 == ("code", .string) })
    }

    @Test("Mermaid highlights diagram keywords and %% comments")
    func mermaidBasics() {
        let source = "%% note\ngraph TD\n  A --> B"
        #expect(token(source, .mermaid, for: "%% note") == .comment)
        #expect(token(source, .mermaid, for: "graph") == .keyword)
        #expect(token(source, .mermaid, for: "TD") == .keyword)
    }

    @Test("Spans never overlap and always sit inside the source")
    func spansAreWellFormed() {
        let samples: [(String, SyntaxLanguage)] = [
            ("let x = \"a\" // c\n/* b */ let Y = 1", .swift),
            ("<div a=\"1\"><!-- c --></div>", .markup),
            ("# h\n```\nx\n```", .markdown),
            ("def f(): # c\n  return 'x'", .python),
            ("graph TD\n A-->B", .mermaid),
        ]
        for (source, language) in samples {
            let spans = SyntaxHighlighter.spans(source, language: language)
            let limit = (source as NSString).length
            var previousEnd = 0
            for span in spans {
                #expect(span.location >= previousEnd, "overlap in \(language): \(span)")
                #expect(span.length > 0, "empty span in \(language)")
                #expect(span.location + span.length <= limit, "span past end in \(language): \(span)")
                previousEnd = span.location + span.length
            }
        }
    }

    @Test("Multi-byte characters keep spans aligned with UTF-16 offsets")
    func unicodeOffsets() {
        // Emoji are two UTF-16 units; a naive character count would slip here.
        let source = "// 🎉 party\nlet x = \"🎉\""
        let spans = SyntaxHighlighter.spans(source, language: .swift)
        for span in spans {
            let text = source as NSString
            #expect(span.location + span.length <= text.length)
        }
        #expect(token(source, .swift, for: "// 🎉 party") == .comment)
        #expect(token(source, .swift, for: "\"🎉\"") == .string)
    }

    @Test("An artifact's kind and language pick the grammar")
    func languageSelection() {
        #expect(SyntaxLanguage.of(kind: .react, language: nil) == .javascript)
        #expect(SyntaxLanguage.of(kind: .svg, language: nil) == .markup)
        #expect(SyntaxLanguage.of(kind: .html, language: nil) == .markup)
        #expect(SyntaxLanguage.of(kind: .mermaid, language: nil) == .mermaid)
        #expect(SyntaxLanguage.of(kind: .markdown, language: nil) == .markdown)
        #expect(SyntaxLanguage.of(kind: .code, language: "swift") == .swift)
        #expect(SyntaxLanguage.of(kind: .code, language: "Python") == .python)
        #expect(SyntaxLanguage.of(kind: .code, language: nil) == .plain)
        #expect(SyntaxLanguage.of(kind: .code, language: "brainfuck") == .plain)
    }

    @Test("A document past the size cap is left alone rather than stuttering")
    func oversizeIsSkipped() {
        let huge = String(repeating: "let x = 1\n", count: 60_000)
        #expect(huge.utf16.count > SyntaxHighlighter.maximumLength)
        #expect(SyntaxHighlighter.spans(huge, language: .swift).isEmpty)
    }

    @Test("Plain text produces no spans at all")
    func plainIsUntouched() {
        #expect(SyntaxHighlighter.spans("let x = 1", language: .plain).isEmpty)
    }
}
