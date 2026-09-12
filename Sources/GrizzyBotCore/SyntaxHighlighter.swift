import Foundation

/// What a run of source text is, for colouring purposes.
public enum SyntaxToken: String, Sendable, Equatable, CaseIterable {
    case plain
    case keyword
    case type
    case string
    case comment
    case number
    case tag
    case attribute
    case punctuation
}

/// A coloured run, as UTF-16 offsets so it maps straight onto `NSRange`.
public struct SyntaxSpan: Sendable, Equatable {
    public var location: Int
    public var length: Int
    public var token: SyntaxToken

    public init(location: Int, length: Int, token: SyntaxToken) {
        self.location = location
        self.length = length
        self.token = token
    }
}

public enum SyntaxLanguage: String, Sendable, Equatable, CaseIterable {
    case swift
    case javascript
    case python
    case shell
    case css
    case json
    case markup      // html, xml, svg
    case markdown
    case mermaid
    case plain

    /// Maps an artifact onto a grammar. `language` only matters for `.code`;
    /// every other kind already knows what it is.
    public static func of(kind: ArtifactKind, language: String?) -> SyntaxLanguage {
        switch kind {
        case .html, .svg: return .markup
        case .markdown: return .markdown
        case .mermaid: return .mermaid
        case .react: return .javascript
        case .code: return named(language)
        }
    }

    public static func named(_ raw: String?) -> SyntaxLanguage {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "swift": return .swift
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "java", "kotlin",
             "c", "cpp", "c++", "objective-c", "go", "rust", "php":
            return .javascript
        case "python", "py", "ruby", "rb", "r", "toml": return .python
        case "bash", "sh", "shell", "zsh", "fish": return .shell
        case "css", "scss", "less": return .css
        case "json": return .json
        case "html", "xml", "svg": return .markup
        case "markdown", "md": return .markdown
        case "mermaid": return .mermaid
        default: return .plain
        }
    }
}

/// A small hand-written scanner rather than a pile of regexes.
///
/// Regexes get this wrong in the ways that are most visible: a `//` inside a
/// string literal, a quote inside a comment, an apostrophe in prose. A single
/// left-to-right pass with explicit state handles those correctly and runs in
/// one traversal, which matters because the editor re-highlights on every
/// keystroke.
public enum SyntaxHighlighter {
    /// Documents past this size are left unhighlighted. Artifacts are normally
    /// far smaller, and a pathological one should not make typing stutter.
    public static let maximumLength = 400_000

    public static func spans(_ source: String, language: SyntaxLanguage) -> [SyntaxSpan] {
        guard language != .plain, source.utf16.count <= maximumLength else { return [] }
        switch language {
        case .markup: return markupSpans(source)
        case .markdown: return markdownSpans(source)
        case .plain: return []
        default: return codeSpans(source, grammar: Grammar.for(language))
        }
    }

    // MARK: - Grammars

    struct Grammar {
        var keywords: Set<String>
        var types: Set<String>
        var lineComment: String?
        var blockComment: (open: String, close: String)?
        var stringDelimiters: Set<Character>
        /// Treat `#` as starting a comment (shell, python) rather than a token.
        var capitalizedAreTypes: Bool

        static func `for`(_ language: SyntaxLanguage) -> Grammar {
            switch language {
            case .swift:
                return Grammar(
                    keywords: [
                        "associatedtype", "as", "async", "await", "break", "case", "catch", "class",
                        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import",
                        "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator",
                        "private", "protocol", "public", "repeat", "return", "self", "static", "struct",
                        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
                        "var", "where", "while", "some", "any", "nonisolated", "actor", "lazy", "weak",
                        "unowned", "override", "final", "mutating", "indirect", "rethrows", "convenience",
                    ],
                    types: ["String", "Int", "Double", "Bool", "Data", "URL", "Date", "Array", "Set", "Dictionary"],
                    lineComment: "//",
                    blockComment: ("/*", "*/"),
                    stringDelimiters: ["\"", "'"],
                    capitalizedAreTypes: true
                )
            case .javascript:
                return Grammar(
                    keywords: [
                        "await", "async", "break", "case", "catch", "class", "const", "continue",
                        "default", "delete", "do", "else", "export", "extends", "false", "finally",
                        "for", "from", "function", "if", "import", "in", "instanceof", "let", "new",
                        "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
                        "try", "typeof", "undefined", "var", "void", "while", "yield", "interface",
                        "type", "enum", "implements", "public", "private", "readonly",
                    ],
                    types: ["React", "Promise", "Array", "Object", "String", "Number", "Boolean", "Math", "JSON"],
                    lineComment: "//",
                    blockComment: ("/*", "*/"),
                    stringDelimiters: ["\"", "'", "`"],
                    capitalizedAreTypes: true
                )
            case .python:
                return Grammar(
                    keywords: [
                        "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                        "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                        "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                        "raise", "return", "True", "try", "while", "with", "yield", "self", "end", "do",
                    ],
                    types: ["str", "int", "float", "bool", "list", "dict", "set", "tuple"],
                    lineComment: "#",
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"],
                    capitalizedAreTypes: false
                )
            case .shell:
                return Grammar(
                    keywords: [
                        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                        "esac", "function", "return", "export", "local", "readonly", "in", "echo",
                        "set", "unset", "source", "exit", "cd", "trap",
                    ],
                    types: [],
                    lineComment: "#",
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"],
                    capitalizedAreTypes: false
                )
            case .css:
                return Grammar(
                    keywords: ["important", "media", "import", "keyframes", "supports", "font-face", "root"],
                    types: [],
                    lineComment: nil,
                    blockComment: ("/*", "*/"),
                    stringDelimiters: ["\"", "'"],
                    capitalizedAreTypes: false
                )
            case .json:
                return Grammar(
                    keywords: ["true", "false", "null"],
                    types: [],
                    lineComment: nil,
                    blockComment: nil,
                    stringDelimiters: ["\""],
                    capitalizedAreTypes: false
                )
            case .mermaid:
                return Grammar(
                    keywords: [
                        "graph", "flowchart", "sequenceDiagram", "classDiagram", "stateDiagram",
                        "erDiagram", "gantt", "pie", "journey", "subgraph", "end", "participant",
                        "actor", "note", "loop", "alt", "opt", "par", "TD", "TB", "LR", "RL", "BT",
                    ],
                    types: [],
                    lineComment: "%%",
                    blockComment: nil,
                    stringDelimiters: ["\""],
                    capitalizedAreTypes: false
                )
            default:
                return Grammar(
                    keywords: [], types: [], lineComment: nil, blockComment: nil,
                    stringDelimiters: [], capitalizedAreTypes: false
                )
            }
        }
    }

    // MARK: - Code scanner

    static func codeSpans(_ source: String, grammar: Grammar) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var offset = 0
        var index = source.startIndex

        func width(_ character: Character) -> Int { character.utf16.count }

        while index < source.endIndex {
            let character = source[index]

            // Comments first: everything inside one is comment, quotes included.
            if let marker = grammar.lineComment, source[index...].hasPrefix(marker) {
                let start = offset
                while index < source.endIndex, source[index] != "\n" {
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                spans.append(SyntaxSpan(location: start, length: offset - start, token: .comment))
                continue
            }
            if let block = grammar.blockComment, source[index...].hasPrefix(block.open) {
                let start = offset
                var closed = false
                while index < source.endIndex {
                    if source[index...].hasPrefix(block.close) {
                        for character in block.close {
                            offset += width(character)
                            index = source.index(after: index)
                        }
                        closed = true
                        break
                    }
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                _ = closed
                spans.append(SyntaxSpan(location: start, length: offset - start, token: .comment))
                continue
            }

            // Strings, honouring backslash escapes so \" does not end them.
            if grammar.stringDelimiters.contains(character) {
                let quote = character
                let start = offset
                offset += width(character)
                index = source.index(after: index)
                while index < source.endIndex {
                    let current = source[index]
                    if current == "\\" {
                        offset += width(current)
                        index = source.index(after: index)
                        if index < source.endIndex {
                            offset += width(source[index])
                            index = source.index(after: index)
                        }
                        continue
                    }
                    offset += width(current)
                    index = source.index(after: index)
                    if current == quote { break }
                    // An unterminated literal stops at the newline rather than
                    // painting the rest of the file, which is what you want
                    // while a quote is still being typed.
                    if current == "\n" { break }
                }
                spans.append(SyntaxSpan(location: start, length: offset - start, token: .string))
                continue
            }

            // Numbers.
            if character.isNumber {
                let start = offset
                while index < source.endIndex,
                      source[index].isHexDigit || source[index] == "." || source[index] == "_"
                        || source[index] == "x" || source[index] == "X" {
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                spans.append(SyntaxSpan(location: start, length: offset - start, token: .number))
                continue
            }

            // Identifiers.
            if character.isLetter || character == "_" || character == "@" || character == "$" {
                let start = offset
                var word = ""
                while index < source.endIndex,
                      source[index].isLetter || source[index].isNumber
                        || source[index] == "_" || source[index] == "@" || source[index] == "$"
                        || source[index] == "-" {
                    word.append(source[index])
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                let bare = word.hasPrefix("@") ? String(word.dropFirst()) : word
                if grammar.keywords.contains(bare) || word.hasPrefix("@") {
                    spans.append(SyntaxSpan(location: start, length: offset - start, token: .keyword))
                } else if grammar.types.contains(bare)
                            || (grammar.capitalizedAreTypes && (bare.first?.isUppercase ?? false)) {
                    spans.append(SyntaxSpan(location: start, length: offset - start, token: .type))
                }
                continue
            }

            offset += width(character)
            index = source.index(after: index)
        }
        return spans
    }

    // MARK: - Markup scanner

    static func markupSpans(_ source: String) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var offset = 0
        var index = source.startIndex

        func width(_ character: Character) -> Int { character.utf16.count }

        while index < source.endIndex {
            if source[index...].hasPrefix("<!--") {
                let start = offset
                while index < source.endIndex, !source[index...].hasPrefix("-->") {
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                for _ in 0..<3 where index < source.endIndex {
                    offset += width(source[index])
                    index = source.index(after: index)
                }
                spans.append(SyntaxSpan(location: start, length: offset - start, token: .comment))
                continue
            }
            guard source[index] == "<" else {
                offset += width(source[index])
                index = source.index(after: index)
                continue
            }

            // Inside a tag: the name is a tag, bare words are attributes, and
            // quoted runs are strings.
            let tagStart = offset
            offset += width(source[index])
            index = source.index(after: index)
            if index < source.endIndex, source[index] == "/" {
                offset += width(source[index])
                index = source.index(after: index)
            }
            var nameLength = 0
            while index < source.endIndex,
                  source[index].isLetter || source[index].isNumber
                    || source[index] == "-" || source[index] == "_" || source[index] == ":" {
                let w = width(source[index])
                offset += w
                nameLength += w
                index = source.index(after: index)
            }
            spans.append(SyntaxSpan(location: tagStart, length: offset - tagStart, token: .tag))

            while index < source.endIndex, source[index] != ">" {
                let character = source[index]
                if character == "\"" || character == "'" {
                    let quote = character
                    let start = offset
                    offset += width(character)
                    index = source.index(after: index)
                    while index < source.endIndex {
                        let current = source[index]
                        offset += width(current)
                        index = source.index(after: index)
                        if current == quote { break }
                    }
                    spans.append(SyntaxSpan(location: start, length: offset - start, token: .string))
                    continue
                }
                if character.isLetter || character == "_" {
                    let start = offset
                    while index < source.endIndex,
                          source[index].isLetter || source[index].isNumber
                            || source[index] == "-" || source[index] == "_" || source[index] == ":" {
                        offset += width(source[index])
                        index = source.index(after: index)
                    }
                    spans.append(SyntaxSpan(location: start, length: offset - start, token: .attribute))
                    continue
                }
                offset += width(character)
                index = source.index(after: index)
            }
            if index < source.endIndex {
                spans.append(SyntaxSpan(location: offset, length: width(source[index]), token: .tag))
                offset += width(source[index])
                index = source.index(after: index)
            }
        }
        return spans
    }

    // MARK: - Markdown scanner

    static func markdownSpans(_ source: String) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var offset = 0
        var inFence = false

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let length = text.utf16.count
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                spans.append(SyntaxSpan(location: offset, length: length, token: .keyword))
            } else if inFence {
                spans.append(SyntaxSpan(location: offset, length: length, token: .string))
            } else if trimmed.hasPrefix("#") {
                spans.append(SyntaxSpan(location: offset, length: length, token: .keyword))
            } else if trimmed.hasPrefix(">") {
                spans.append(SyntaxSpan(location: offset, length: length, token: .comment))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let dashOffset = offset + (length - trimmed.utf16.count)
                spans.append(SyntaxSpan(location: dashOffset, length: 1, token: .tag))
            }
            offset += length + 1  // the newline split consumed
        }
        return spans
    }
}
