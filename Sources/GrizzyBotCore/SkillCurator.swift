import Foundation

/// How a skill has actually been used. Kept in a small JSON file beside the skill library so the
/// workspace config is untouched.
public struct SkillUsageRecord: Codable, Sendable, Equatable {
    public var loads: Int = 0
    public var firstSeen: Date
    public var lastUsed: Date?
    /// A pinned skill is never suggested for archiving or merging.
    public var pinned: Bool = false
    /// Bot that proposed this skill; nil for skills a person wrote or imported.
    public var proposedBy: String?
    /// True while a proposed skill still waits for the person's yes.
    public var awaitingReview: Bool = false

    public init(firstSeen: Date) { self.firstSeen = firstSeen }
}

public struct SkillUsageStore: Codable, Sendable, Equatable {
    public var records: [String: SkillUsageRecord] = [:]

    public init() {}

    public static func fileURL(root: URL) -> URL { root.appendingPathComponent("skill-usage.json") }

    public static func load(root: URL) -> SkillUsageStore {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let store = try? JSONDecoder.iso.decode(SkillUsageStore.self, from: data) else { return SkillUsageStore() }
        return store
    }

    public func save(root: URL) {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: Self.fileURL(root: root), options: .atomic)
    }

    public mutating func recordUse(_ id: String, now: Date = .now) {
        var record = records[id] ?? SkillUsageRecord(firstSeen: now)
        record.loads += 1
        record.lastUsed = now
        records[id] = record
    }

    /// Make sure every skill has a `firstSeen`, so "never used" has a start date.
    public mutating func noteSkills(_ ids: [String], now: Date = .now) {
        for id in ids where records[id] == nil { records[id] = SkillUsageRecord(firstSeen: now) }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

public struct CuratorSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case archive, merge }
    public var kind: Kind
    public var skillIds: [String]
    public var reason: String
    public var id: String { "\(kind.rawValue):\(skillIds.joined(separator: "+"))" }
}

/// Hermes's best skill idea, with its safety rule kept: a curator may *suggest* tidying, but it only
/// ever archives (never deletes), never touches bundled or pinned skills, and the person decides.
public enum SkillCurator {
    public static func review(
        skills: [AgentSkill],
        usage: SkillUsageStore,
        now: Date = .now,
        idleDays: Int = 45,
        mergeThreshold: Double = 0.6
    ) -> [CuratorSuggestion] {
        let candidates = skills.filter { skill in
            skill.source == .user
                && usage.records[skill.id]?.pinned != true
                && usage.records[skill.id]?.awaitingReview != true
        }
        var out: [CuratorSuggestion] = []
        let idle = TimeInterval(idleDays) * 86_400

        for skill in candidates {
            guard let record = usage.records[skill.id] else { continue }
            if record.loads == 0, now.timeIntervalSince(record.firstSeen) > idle {
                out.append(CuratorSuggestion(
                    kind: .archive,
                    skillIds: [skill.id],
                    reason: "Never used in \(idleDays)+ days."
                ))
            } else if let last = record.lastUsed, now.timeIntervalSince(last) > idle * 2 {
                out.append(CuratorSuggestion(
                    kind: .archive,
                    skillIds: [skill.id],
                    reason: "Not used since \(last.formatted(date: .abbreviated, time: .omitted))."
                ))
            }
        }

        let archived = Set(out.flatMap(\.skillIds))
        let live = candidates.filter { !archived.contains($0.id) }
        let fingerprints = live.map { ($0, tokens(of: $0)) }
        for i in 0..<fingerprints.count {
            for j in (i + 1)..<max(i + 1, fingerprints.count) {
                let score = jaccard(fingerprints[i].1, fingerprints[j].1)
                if score >= mergeThreshold {
                    out.append(CuratorSuggestion(
                        kind: .merge,
                        skillIds: [fingerprints[i].0.id, fingerprints[j].0.id],
                        reason: "These two read \(Int(score * 100))% alike. Consider keeping one."
                    ))
                }
            }
        }
        return out
    }

    static func tokens(of skill: AgentSkill) -> Set<String> {
        let text = ([skill.description] + skill.keywords + [String(skill.body.prefix(600))]).joined(separator: " ")
        return Set(MemoryIndex.tokenize(text).filter { $0.count > 2 })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

extension SkillLibrary {
    public static func archiveDirectory(root: URL) -> URL {
        directory(root: root).appendingPathComponent(".archive", isDirectory: true)
    }

    /// Move a skill out of the live library without deleting it.
    @discardableResult
    public static func archiveUserSkill(id: String, root: URL, now: Date = .now) throws -> URL {
        let slug = SkillMarkdown.slug(id)
        let source = directory(root: root).appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { throw BotHomeError.notFound(slug) }
        let archive = archiveDirectory(root: root)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        let destination = archive.appendingPathComponent("\(slug)@\(stamp)", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    public static func archivedNames(root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory(root: root).path)) ?? []).sorted()
    }

    /// Put an archived skill back. If the id is taken again, the restore is refused rather than overwriting.
    @discardableResult
    public static func restoreArchived(name: String, root: URL) throws -> String {
        let source = archiveDirectory(root: root).appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { throw BotHomeError.notFound(name) }
        let id = name.split(separator: "@").first.map(String.init) ?? name
        let destination = directory(root: root).appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BotHomeError.notFound("a skill named \(id) already exists")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return id
    }
}

public enum SkillLearning {
    /// `/learn`: look back over this conversation and propose a reusable skill — never install one.
    public static func prompt(topic: String) -> String {
        let focus = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Review the work in this conversation\(focus.isEmpty ? "" : " about: \(focus)"). If it contains a repeatable procedure worth keeping, \
        call skill_propose once with a short id, a one-line description specific enough to pick it from a catalog, \
        and a concise body of numbered steps that name the tools to use. Do not include secrets, private data, \
        or anything specific to one person's files. The proposal is saved switched off for the person to review. \
        If nothing here is worth turning into a skill, say so and do not call the tool.
        """
    }
}
