import Foundation

/// What an artifact is made of. The raw values are GrizzyBot's own, but
/// `parse` also accepts the media types Claude Desktop uses, so a model that
/// has seen those emits a usable `type` without being retrained.
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case markdown
    case code
    case html
    case svg
    case mermaid
    case react

    public static func parse(_ raw: String) -> ArtifactKind? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "markdown", "md", "text/markdown", "document": return .markdown
        case "code", "application/vnd.ant.code", "source": return .code
        case "html", "text/html", "application/vnd.ant.html": return .html
        case "svg", "image/svg+xml", "application/vnd.ant.svg": return .svg
        case "mermaid", "application/vnd.ant.mermaid", "diagram": return .mermaid
        case "react", "jsx", "tsx", "application/vnd.ant.react": return .react
        default: return nil
        }
    }

    /// Rendered in a web view rather than by native SwiftUI.
    public var needsWebFrame: Bool {
        switch self {
        case .markdown, .code: return false
        case .html, .svg, .mermaid, .react: return true
        }
    }

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .code: return "Code"
        case .html: return "HTML"
        case .svg: return "SVG"
        case .mermaid: return "Diagram"
        case .react: return "React"
        }
    }

    /// Opening contents for an artifact made by hand. The store refuses empty
    /// content, and more usefully, a new visual artifact that rendered as a
    /// blank frame would read as broken rather than as empty.
    public var starterContent: String {
        switch self {
        case .markdown:
            return "# Untitled\n\nStart writing.\n"
        case .code:
            return "// Start here.\n"
        case .html:
            return "<div style=\"padding:24px;font:15px system-ui\">\n  <h1>Untitled</h1>\n  <p>Start here.</p>\n</div>\n"
        case .svg:
            return "<svg viewBox=\"0 0 240 120\" xmlns=\"http://www.w3.org/2000/svg\">\n  <rect x=\"8\" y=\"8\" width=\"224\" height=\"104\" rx=\"12\" fill=\"none\" stroke=\"#888\"/>\n  <text x=\"120\" y=\"66\" text-anchor=\"middle\" fill=\"#888\" font-size=\"14\">Untitled</text>\n</svg>\n"
        case .mermaid:
            return "graph TD\n  Start --> Finish\n"
        case .react:
            return "export default function App() {\n  return (\n    <div className=\"p-8\">\n      <h1 className=\"text-2xl font-semibold\">Untitled</h1>\n      <p className=\"text-gray-500\">Start here.</p>\n    </div>\n  );\n}\n"
        }
    }

    /// Extension for the working-folder mirror.
    public func fileExtension(language: String?) -> String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        case .svg: return "svg"
        case .mermaid: return "mmd"
        case .react: return "jsx"
        case .code: return ArtifactLanguage.fileExtension(for: language)
        }
    }
}

public enum ArtifactLanguage {
    /// Only the languages worth a distinct extension; anything else keeps `.txt`
    /// so a mirrored file never claims a type it isn't.
    static let extensions: [String: String] = [
        "swift": "swift", "python": "py", "javascript": "js", "typescript": "ts",
        "jsx": "jsx", "tsx": "tsx", "json": "json", "yaml": "yaml", "yml": "yaml",
        "bash": "sh", "sh": "sh", "shell": "sh", "zsh": "sh",
        "html": "html", "css": "css", "sql": "sql", "rust": "rs", "go": "go",
        "ruby": "rb", "java": "java", "kotlin": "kt", "c": "c", "cpp": "cpp",
        "objective-c": "m", "php": "php", "xml": "xml", "toml": "toml", "text": "txt",
    ]

    public static func fileExtension(for language: String?) -> String {
        guard let language else { return "txt" }
        return extensions[language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? "txt"
    }
}

/// One saved state of an artifact. Version 1 is the create; every later content
/// change appends another, so the panel can step back through history the way
/// Claude Desktop does.
public struct ArtifactVersion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var content: String
    public var note: String
    public var createdAt: Date

    public init(id: String = Ids.new(), content: String, note: String = "", createdAt: Date = .now) {
        self.id = id
        self.content = content
        self.note = note
        self.createdAt = createdAt
    }
}

/// Shared on this Mac: every bot can list, read, update, and delete the same
/// artifacts, and each one remembers which bot created it.
public struct ArtifactRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var kind: ArtifactKind
    public var language: String?
    public var content: String
    public var versions: [ArtifactVersion]
    public var botId: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Working-folder path this artifact was last mirrored to, if any.
    public var mirroredPath: String?
    /// Set when this artifact *is* a skill's SKILL.md opened for editing. Saving
    /// such an artifact writes the skill library, so the two never drift apart.
    public var linkedSkillId: String?

    public init(
        id: String,
        title: String,
        kind: ArtifactKind,
        language: String? = nil,
        content: String,
        versions: [ArtifactVersion] = [],
        botId: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        mirroredPath: String? = nil,
        linkedSkillId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.language = language
        self.content = content
        self.versions = versions
        self.botId = botId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mirroredPath = mirroredPath
        self.linkedSkillId = linkedSkillId
    }

    public var versionCount: Int { max(1, versions.count) }

    /// Named from the id, not the title: ids are unique by construction, so
    /// two artifacts that happen to share a title cannot overwrite each
    /// other's mirrored file. When the model omits an id it is derived from
    /// the title anyway, so the common case still reads as the title.
    public var fileName: String {
        "\(id).\(kind.fileExtension(language: language))"
    }

    /// One-line description for tool output and chat cards.
    public var summary: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let detail = kind == .code ? (language ?? "code") : kind.label
        return "\(detail) · \(lines) line\(lines == 1 ? "" : "s") · v\(versionCount)"
    }
}

public enum ArtifactError: Error, LocalizedError, Sendable, Equatable {
    case notFound(String)
    case duplicateId(String)
    case emptyContent
    case emptyTitle
    case unknownKind(String)
    case targetNotFound(String)
    case targetNotUnique(String, Int)
    case unchanged

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "No artifact with id \(id). Call artifact_list to see what exists."
        case .duplicateId(let id):
            return "Artifact \(id) already exists — call artifact_update or artifact_rewrite to change it."
        case .emptyContent:
            return "An artifact needs content."
        case .emptyTitle:
            return "An artifact needs a title."
        case .unknownKind(let raw):
            let known = ArtifactKind.allCases.map(\.rawValue).joined(separator: ", ")
            return "\(raw) is not an artifact type. Use one of: \(known)."
        case .targetNotFound(let text):
            return "old_str was not found in the artifact: \(Self.excerpt(text))"
        case .targetNotUnique(let text, let count):
            return "old_str appears \(count) times — include more surrounding text so it matches once: \(Self.excerpt(text))"
        case .unchanged:
            return "new_str is identical to old_str, so nothing would change."
        }
    }

    private static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 80 ? flat : String(flat.prefix(77)) + "…"
    }
}

/// File-backed artifact store, shared by every bot on this Mac.
///
/// Mirrors `CanvasBoardStore`: one `index.json` plus a folder per artifact, so
/// a routine that runs while the app is closed and the chat UI read the same
/// state without a migration step.
public struct ArtifactStore: Sendable {
    public static let toolIds: [String] = [
        "artifact_create", "artifact_update", "artifact_rewrite",
        "artifact_list", "artifact_read", "artifact_delete",
    ]

    public let root: URL

    public init(root: URL) {
        self.root = root.appendingPathComponent("artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func list() -> [ArtifactRecord] {
        loadIndex().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Resolves by id first, then by title, so a model that lost the id can
    /// still reach the artifact it just made.
    public func load(id: String) -> ArtifactRecord? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let records = loadIndex()
        if let exact = records.first(where: { $0.id == trimmed }) { return exact }
        return records.first { $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    @discardableResult
    public func create(
        id rawId: String,
        title: String,
        kind: ArtifactKind,
        language: String?,
        content: String,
        botId: String?
    ) throws -> ArtifactRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw ArtifactError.emptyTitle }
        guard !content.isEmpty else { throw ArtifactError.emptyContent }

        let id = Self.slug(rawId.isEmpty ? trimmedTitle : rawId)
        if loadIndex().contains(where: { $0.id == id }) {
            throw ArtifactError.duplicateId(id)
        }
        let record = ArtifactRecord(
            id: id,
            title: trimmedTitle,
            kind: kind,
            language: language?.isEmpty == true ? nil : language,
            content: content,
            versions: [ArtifactVersion(content: content, note: "Created")],
            botId: botId
        )
        return try write(record)
    }

    /// Targeted replacement. `oldString` must appear exactly once — an
    /// ambiguous match is refused rather than guessed at, because the wrong
    /// occurrence silently corrupts the artifact.
    @discardableResult
    public func update(id: String, oldString: String, newString: String) throws -> ArtifactRecord {
        guard var record = load(id: id) else { throw ArtifactError.notFound(id) }
        guard !oldString.isEmpty else { throw ArtifactError.targetNotFound(oldString) }
        guard oldString != newString else { throw ArtifactError.unchanged }

        let occurrences = record.content.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else { throw ArtifactError.targetNotFound(oldString) }
        guard occurrences == 1 else { throw ArtifactError.targetNotUnique(oldString, occurrences) }

        record.content = record.content.replacingOccurrences(of: oldString, with: newString)
        record.versions.append(ArtifactVersion(content: record.content, note: "Edited"))
        record.updatedAt = .now
        return try write(record)
    }

    /// Whole-content replacement, for changes too broad to express as an edit.
    @discardableResult
    public func rewrite(id: String, content: String, title: String?) throws -> ArtifactRecord {
        guard var record = load(id: id) else { throw ArtifactError.notFound(id) }
        guard !content.isEmpty else { throw ArtifactError.emptyContent }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        record.content = content
        record.versions.append(ArtifactVersion(content: content, note: "Rewritten"))
        record.updatedAt = .now
        return try write(record)
    }

    @discardableResult
    public func delete(id: String) throws -> ArtifactRecord {
        guard let match = load(id: id) else { throw ArtifactError.notFound(id) }
        var records = loadIndex()
        records.removeAll { $0.id == match.id }
        try writeIndex(records)
        try? FileManager.default.removeItem(at: folder(for: match.id))
        return match
    }

    /// Records where the artifact was mirrored on disk. Kept separate from
    /// `rewrite` so a failed mirror never loses the content itself.
    @discardableResult
    public func noteMirror(id: String, path: String?) throws -> ArtifactRecord {
        guard var record = load(id: id) else { throw ArtifactError.notFound(id) }
        record.mirroredPath = path
        return try write(record, touch: false)
    }

    /// Binds an artifact to the skill it was opened from. Like `noteMirror`,
    /// kept out of `rewrite` so it never costs a version.
    @discardableResult
    public func link(id: String, skillId: String?) throws -> ArtifactRecord {
        guard var record = load(id: id) else { throw ArtifactError.notFound(id) }
        record.linkedSkillId = skillId
        return try write(record, touch: false)
    }

    // MARK: - Disk

    @discardableResult
    private func write(_ record: ArtifactRecord, touch: Bool = true) throws -> ArtifactRecord {
        var copy = record
        if touch { copy.updatedAt = .now }
        try FileManager.default.createDirectory(at: folder(for: copy.id), withIntermediateDirectories: true)
        // The content also lands beside the index as a readable file, so the
        // artifact survives an index that a future migration cannot decode.
        try? Data(copy.content.utf8).write(to: contentURL(id: copy.id, fileName: copy.fileName), options: .atomic)
        var records = loadIndex().filter { $0.id != copy.id }
        records.append(copy)
        try writeIndex(records)
        return copy
    }

    private func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func contentURL(id: String, fileName: String) -> URL {
        folder(for: id).appendingPathComponent(fileName)
    }

    private func indexURL() -> URL {
        root.appendingPathComponent("index.json")
    }

    private func loadIndex() -> [ArtifactRecord] {
        guard let data = try? Data(contentsOf: indexURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ArtifactRecord].self, from: data)) ?? []
    }

    private func writeIndex(_ records: [ArtifactRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: indexURL(), options: .atomic)
    }

    /// Lowercase, hyphenated, filesystem-safe — and never empty, so it is
    /// always usable as both a directory name and a tool-facing id.
    public static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        let capped = String(out.prefix(60))
        return capped.isEmpty ? "artifact-\(Ids.new().prefix(8))" : capped
    }
}

/// Result of mirroring an artifact to disk: the (possibly updated) record, the
/// path it reached, and why it did not, if it did not.
public struct ArtifactMirror: Sendable {
    public var record: ArtifactRecord
    public var path: String?
    public var error: String?

    public init(record: ArtifactRecord, path: String?, error: String?) {
        self.record = record
        self.path = path
        self.error = error
    }
}

/// What happened when a hand edit was saved from the panel.
public enum ArtifactSaveOutcome: Sendable, Equatable {
    case unchanged
    case saved
    /// Saved, but the artifact had gained versions since editing began —
    /// a bot or routine wrote to it meanwhile. Nothing is lost (versions are
    /// append-only), but the panel says so rather than quietly winning.
    case savedOverNewerVersions(Int)
    case failed(String)
}
