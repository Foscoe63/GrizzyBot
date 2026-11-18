import Foundation
import NaturalLanguage

/// Reversible placeholders for one conversation: `[EMAIL_1]` stands for the same address every time it
/// appears, so the reply can be put back the way the person wrote it. Choices the person made in the
/// review (this one is fine to send) are remembered for the conversation too.
public final class RedactionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var forward: [String: String] = [:]   // original -> placeholder
    private var reverse: [String: String] = [:]   // placeholder -> original
    private var counters: [PIIType: Int] = [:]
    private var allowed: Set<String> = []

    public init() {}

    public func placeholder(for original: String, type: PIIType) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(type.rawValue)|\(original)"
        if let existing = forward[key] { return existing }
        let n = (counters[type] ?? 0) + 1
        counters[type] = n
        let tag = "[\(type.rawValue.uppercased())_\(n)]"
        forward[key] = tag
        reverse[tag] = original
        return tag
    }

    /// The person reviewed this and chose to send it as it is.
    public func allow(_ original: String) {
        lock.lock(); allowed.insert(original.lowercased()); lock.unlock()
    }

    public func isAllowed(_ original: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed.contains(original.lowercased())
    }

    public var knownPlaceholders: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return reverse
    }

    /// Puts the original text back wherever a placeholder appears.
    public func unscrub(_ text: String) -> String {
        let map = knownPlaceholders
        guard !map.isEmpty, text.contains("[") else { return text }
        var out = text
        for (tag, original) in map { out = out.replacingOccurrences(of: tag, with: original) }
        return out
    }

    public static func isNeverRedact(_ text: String, list: [String]) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return list.contains { entry in
            let e = entry.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !e.isEmpty && (e == lowered || lowered.contains(e))
        }
    }
}

/// Unscrubs placeholders in a streamed reply. A placeholder can be cut in half by chunking
/// (`[EMA` then `IL_1]`), so a trailing partial tag is held back until the next chunk settles it.
public struct StreamingUnscrubber {
    private let session: RedactionSession
    private var held = ""

    public init(session: RedactionSession) { self.session = session }

    public mutating func feed(_ chunk: String) -> String {
        var text = held + chunk
        held = ""
        if let open = text.lastIndex(of: "["), !text[open...].contains("]") {
            let tail = String(text[open...])
            // Only hold what could still become a placeholder.
            if tail.count <= 24, tail.dropFirst().allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                held = tail
                text = String(text[..<open])
            }
        }
        return session.unscrub(text)
    }

    /// Flushes anything held when the stream ends.
    public mutating func finish() -> String {
        let rest = held
        held = ""
        return session.unscrub(rest)
    }
}

/// Finds people, places and organisations with Apple's on-device language model (no download, nothing
/// leaves the Mac). Opt-in, since names are fuzzy: it can flag a product or a city you did not mean.
public enum OnDeviceEntityDetector {
    public static func detect(in text: String) -> [PIIDetection] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var out: [PIIDetection] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let type: PIIType
            switch tag {
            case .personalName: type = .person
            case .placeName: type = .place
            case .organizationName: type = .organization
            default: return true
            }
            let original = String(text[range])
            guard original.count >= 3 else { return true }
            out.append(PIIDetection(
                type: type,
                originalText: original,
                redactedText: "[REDACTED \(type.rawValue.uppercased())]",
                confidence: 0.85,
                range: range
            ))
            return true
        }
        return out
    }
}

/// What the review sheet shows: the message as segments, so the original and the scrubbed version can
/// sit side by side with the sensitive spans marked.
public struct RedactionPreview: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var original: String
        public var replacement: String?
        public var type: PIIType?
        public var isRedacted: Bool { replacement != nil }
    }
    public var segments: [Segment]
    public var scrubbed: String { segments.map { $0.replacement ?? $0.original }.joined() }
    public var original: String { segments.map(\.original).joined() }

    public static func make(for text: String, settings: PrivacyFilterSettings, session: RedactionSession? = nil) -> RedactionPreview {
        let result = PrivacyFilter.redact(text, settings: settings, session: session)
        var spans: [(range: Range<String.Index>, detection: PIIDetection)] = []
        for d in result.detections { if let r = d.range, r.upperBound <= text.endIndex { spans.append((r, d)) } }
        spans.sort { $0.range.lowerBound < $1.range.lowerBound }
        var segments: [Segment] = []
        var cursor = text.startIndex
        for span in spans where span.range.lowerBound >= cursor {
            if span.range.lowerBound > cursor { segments.append(.init(original: String(text[cursor..<span.range.lowerBound]), replacement: nil, type: nil)) }
            segments.append(.init(original: String(text[span.range]), replacement: span.detection.redactedText, type: span.detection.type))
            cursor = span.range.upperBound
        }
        if cursor < text.endIndex { segments.append(.init(original: String(text[cursor...]), replacement: nil, type: nil)) }
        return RedactionPreview(segments: segments)
    }
}
