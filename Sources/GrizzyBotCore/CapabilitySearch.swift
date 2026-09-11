import Foundation

public enum CapabilityKind: String, Sendable, Codable, Equatable {
    case skill
    case builtin
    case mcp
}

public struct CapabilityIndexEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: CapabilityKind
    public var name: String
    public var description: String
    public var keywords: [String]

    public init(
        id: String,
        kind: CapabilityKind,
        name: String,
        description: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.keywords = keywords
    }

    public var indexText: String {
        ([id, name, description] + keywords).joined(separator: " ")
    }
}

public struct CapabilityHit: Sendable, Equatable {
    public var entry: CapabilityIndexEntry
    public var score: Double

    public init(entry: CapabilityIndexEntry, score: Double) {
        self.entry = entry
        self.score = score
    }
}

/// BM25 over skills, builtins, and known MCP tools — Osaurus-style discover without Vectura.
public enum CapabilitySearch {
    public static func entries(
        skills: [AgentSkill],
        builtins: [AgentToolDefinition] = AgentToolCatalog.builtin,
        mcpAdvertised: [String: [String]] = [:],
        promotedMcp: [McpPromotedTool] = []
    ) -> [CapabilityIndexEntry] {
        var out: [CapabilityIndexEntry] = []
        var seen = Set<String>()

        func add(_ entry: CapabilityIndexEntry) {
            let key = "\(entry.kind.rawValue):\(entry.id)"
            guard seen.insert(key).inserted else { return }
            out.append(entry)
        }

        for skill in skills {
            add(
                CapabilityIndexEntry(
                    id: skill.id,
                    kind: .skill,
                    name: skill.name,
                    description: skill.description,
                    keywords: skill.keywords
                )
            )
        }
        for tool in builtins {
            add(
                CapabilityIndexEntry(
                    id: tool.id,
                    kind: .builtin,
                    name: tool.label,
                    description: tool.subtitle,
                    keywords: [tool.id]
                )
            )
        }
        for (serverId, names) in mcpAdvertised {
            for name in names {
                add(
                    CapabilityIndexEntry(
                        id: name,
                        kind: .mcp,
                        name: name,
                        description: "MCP tool on \(serverId)",
                        keywords: [serverId, name]
                    )
                )
            }
        }
        for promo in promotedMcp {
            add(
                CapabilityIndexEntry(
                    id: promo.chatName,
                    kind: .mcp,
                    name: promo.chatName,
                    description: promo.description.isEmpty
                        ? "Promoted MCP tool on \(promo.serverId)"
                        : promo.description,
                    keywords: [promo.serverId, promo.executeTool]
                )
            )
        }
        return out
    }

    public static func search(
        _ query: String,
        in catalog: [CapabilityIndexEntry],
        topK: Int = 8,
        kinds: Set<CapabilityKind>? = nil
    ) -> [CapabilityHit] {
        let tokens = MemoryIndex.tokenize(query)
        guard !tokens.isEmpty, !catalog.isEmpty else { return [] }
        let filtered = kinds.map { want in catalog.filter { want.contains($0.kind) } } ?? catalog
        guard !filtered.isEmpty else { return [] }

        let chunks: [(entry: CapabilityIndexEntry, tokens: [String])] = filtered.map {
            ($0, MemoryIndex.tokenize($0.indexText))
        }
        var df: [String: Int] = [:]
        for chunk in chunks {
            for term in Set(chunk.tokens) {
                df[term, default: 0] += 1
            }
        }
        let n = Double(chunks.count)
        let avgdl = chunks.map { Double($0.tokens.count) }.reduce(0, +) / Double(max(1, chunks.count))
        let k1 = 1.5
        let b = 0.75

        var hits: [CapabilityHit] = []
        for chunk in chunks {
            var tf: [String: Int] = [:]
            for term in chunk.tokens { tf[term, default: 0] += 1 }
            var bm25 = 0.0
            for term in tokens {
                let freq = Double(tf[term] ?? 0)
                guard freq > 0 else { continue }
                let docsWith = Double(df[term] ?? 0)
                let idf = log((n - docsWith + 0.5) / (docsWith + 0.5) + 1)
                let dl = Double(max(1, chunk.tokens.count))
                let denom = freq + k1 * (1 - b + b * dl / max(avgdl, 1))
                bm25 += idf * (freq * (k1 + 1)) / denom
            }
            // Prefer exact id / name hits.
            let lower = query.lowercased()
            if chunk.entry.id.lowercased() == lower || chunk.entry.name.lowercased() == lower {
                bm25 += 5
            } else if lower.contains(chunk.entry.id.lowercased()) {
                bm25 += 2
            }
            guard bm25 > 0 else { continue }
            hits.append(CapabilityHit(entry: chunk.entry, score: bm25))
        }
        return Array(
            hits.sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
                return lhs.entry.id < rhs.entry.id
            }
            .prefix(max(1, topK))
        )
    }

    public static func formatDiscover(_ hits: [CapabilityHit]) -> String {
        guard !hits.isEmpty else {
            return "No matching capabilities. Try a broader query, or call mcp_list_tools / read_skill."
        }
        var lines = ["Discovered capabilities (call capabilities_load with ids to activate):"]
        for hit in hits {
            let score = String(format: "%.2f", hit.score)
            lines.append(
                "- [\(hit.entry.kind.rawValue)] \(hit.entry.id) — \(hit.entry.description) (score \(score))"
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Mid-turn loads from `capabilities_load` (skills + MCP promotions).
public struct CapabilityLoadResult: Sendable {
    public var skillBodies: [(id: String, body: String)]
    public var promotedMcp: [McpPromotedTool]
    public var notes: [String]

    public init(
        skillBodies: [(id: String, body: String)] = [],
        promotedMcp: [McpPromotedTool] = [],
        notes: [String] = []
    ) {
        self.skillBodies = skillBodies
        self.promotedMcp = promotedMcp
        self.notes = notes
    }
}
