import Foundation

/// Turns selected chat text into a Markdown quote ahead of whatever is already being typed.
public enum QuoteFormatter {
    public static let maxCharacters = 4_000

    public static func blockquote(_ selection: String) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clipped = trimmed.count > maxCharacters ? String(trimmed.prefix(maxCharacters)) + "…" : trimmed
        return clipped.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }

    /// The draft with the quote on top and the cursor space left below it.
    public static func compose(draft: String, quote: String) -> String {
        guard let block = blockquote(quote) else { return draft }
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? block + "\n\n" : block + "\n\n" + rest
    }
}
