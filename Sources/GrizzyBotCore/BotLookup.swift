import Foundation

/// Finds a bot from whatever the model typed. Models put a name in an `id` field and an id in a `name`
/// field all the time; the answer should not depend on which they picked.
public enum BotLookup {
    public enum Result: Equatable {
        case found(Bot)
        case ambiguous([Bot])
        case none
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Tries each query in order. For each: exact id, exact name, name ignoring spaces and punctuation, then a
    /// unique prefix, then a unique substring. The first query that matches anything decides the result;
    /// a tier with more than one match is ambiguous rather than a guess.
    public static func resolve(_ queries: [String], in bots: [Bot]) -> Result {
        for raw in queries {
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            let key = normalize(query)

            let tiers: [[Bot]] = [
                bots.filter { $0.id == query },
                bots.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame },
                key.isEmpty ? [] : bots.filter { normalize($0.name) == key },
                key.isEmpty ? [] : bots.filter { normalize($0.name).hasPrefix(key) },
                key.count >= 3 ? bots.filter { normalize($0.name).contains(key) } : [],
            ]
            for tier in tiers where !tier.isEmpty {
                return tier.count == 1 ? .found(tier[0]) : .ambiguous(tier)
            }
        }
        return .none
    }
}
