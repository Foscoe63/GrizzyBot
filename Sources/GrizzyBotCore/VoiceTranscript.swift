import Foundation

/// Word positions for a spoken reply, so the text can be highlighted as it is read and a tap on a
/// word can start reading from there. Offsets are UTF-16 (what `NSString` and the speech engine use).
public enum VoiceTranscript {
    public struct Word: Equatable, Sendable {
        public var offset: Int
        public var length: Int
        public var end: Int { offset + length }
        public init(offset: Int, length: Int) { self.offset = offset; self.length = length }
    }

    /// The reply as it is spoken and shown during playback: Markdown marks removed, links keep their text.
    public static func plainText(fromMarkdown markdown: String) -> String {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func words(in text: String) -> [Word] {
        let ns = text as NSString
        var out: [Word] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            out.append(Word(offset: range.location, length: range.length))
        }
        return out
    }

    /// Index of the word containing `offset`, or the next one if it falls in a gap.
    public static func wordIndex(at offset: Int, in words: [Word]) -> Int? {
        if let hit = words.firstIndex(where: { offset >= $0.offset && offset < $0.end }) { return hit }
        return words.firstIndex { $0.offset >= offset }
    }

    /// The text from `offset` on, for resuming playback mid-reply.
    public static func suffix(of text: String, from offset: Int) -> String {
        let ns = text as NSString
        guard offset > 0, offset < ns.length else { return text }
        return ns.substring(from: offset)
    }
}
