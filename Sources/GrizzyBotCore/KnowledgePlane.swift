import Foundation

public enum KnowledgeSourceKind: String, Codable, Sendable {
    case folder
    case plugin
}

public struct KnowledgeSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: KnowledgeSourceKind
    /// Folder path, or plugin slug.
    public var path: String
    /// Subfolders of `path` to index, relative to it. Empty means the whole folder.
    public var roots: [String]
    /// Empty means every bot. Otherwise only these bots may search it.
    public var grantedBotIds: [String]
    /// A disabled source is kept but never indexed or searched.
    public var enabled: Bool

    public init(
        id: String = Ids.new(),
        name: String,
        kind: KnowledgeSourceKind = .folder,
        path: String,
        roots: [String] = [],
        grantedBotIds: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.roots = roots
        self.grantedBotIds = grantedBotIds
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, path, roots, grantedBotIds, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(KnowledgeSourceKind.self, forKey: .kind)
        path = try c.decode(String.self, forKey: .path)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        grantedBotIds = try c.decodeIfPresent([String].self, forKey: .grantedBotIds) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func allows(botId: String) -> Bool {
        grantedBotIds.isEmpty || grantedBotIds.contains(botId)
    }
}

public struct KnowledgeHit: Sendable, Equatable {
    public var sourceId: String
    public var sourceName: String
    /// Absolute file path for folder sources, the plugin slug for plugin sources.
    public var path: String
    /// Path inside the source folder.
    public var relativePath: String
    /// File title plus the heading trail of the matching section.
    public var title: String
    public var snippet: String
    /// Combined relevance, 0...1.
    public var score: Double
    public var keywordScore: Double
    /// Cosine similarity of the section to the query, when embeddings are available.
    public var semanticScore: Double?
    /// Notes this section links to with `[[wikilinks]]`, relative to the source.
    public var linked: [String]

    public init(
        sourceId: String,
        sourceName: String,
        path: String,
        snippet: String,
        score: Double,
        relativePath: String = "",
        title: String = "",
        keywordScore: Double = 0,
        semanticScore: Double? = nil,
        linked: [String] = []
    ) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.path = path
        self.relativePath = relativePath
        self.title = title
        self.snippet = snippet
        self.score = score
        self.keywordScore = keywordScore
        self.semanticScore = semanticScore
        self.linked = linked
    }
}

public struct KnowledgeIndexStats: Sendable, Equatable {
    public var sourceId: String
    public var indexedFiles: Int
    public var skippedFiles: Int
    /// Files read from disk on the last refresh; the rest came from the cache.
    public var reparsedFiles: Int
    public var chunks: Int
    public var semanticChunks: Int
    /// Why files were skipped, and any subfolders that were ignored.
    public var notes: [String]
    public var refreshedAt: Date

    public init(
        sourceId: String,
        indexedFiles: Int = 0,
        skippedFiles: Int = 0,
        reparsedFiles: Int = 0,
        chunks: Int = 0,
        semanticChunks: Int = 0,
        notes: [String] = [],
        refreshedAt: Date = .now
    ) {
        self.sourceId = sourceId
        self.indexedFiles = indexedFiles
        self.skippedFiles = skippedFiles
        self.reparsedFiles = reparsedFiles
        self.chunks = chunks
        self.semanticChunks = semanticChunks
        self.notes = notes
        self.refreshedAt = refreshedAt
    }

    public var summary: String {
        "\(indexedFiles) files indexed, \(skippedFiles) skipped · \(chunks) sections"
    }
}

public enum KnowledgePlane {
    /// Sources a bot may search: enabled, and either ungated or granted to it.
    public static func sourcesVisible(to botId: String, from sources: [KnowledgeSource]) -> [KnowledgeSource] {
        sources.filter { $0.enabled && $0.allows(botId: botId) }
    }

    public static func isCloudPlugin(_ slug: String) -> Bool {
        let folded = slug.lowercased()
        return [
            "google-drive", "googledrive", "gdrive",
            "onedrive", "microsoft-onedrive",
            "box", "dropbox",
        ].contains(folded)
    }
}

/// Keeps a source's files inside the folder the owner chose.
public enum KnowledgePaths {
    public static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    public static func contains(_ base: URL, _ child: URL) -> Bool {
        let b = base.pathComponents
        let c = child.pathComponents
        return c.count >= b.count && Array(c.prefix(b.count)) == b
    }

    /// Subfolders that resolve inside `base`, and the entries that were refused.
    /// Absolute paths, `~`, and anything that climbs out through `..` or a symlink are refused.
    public static func resolveRoots(_ roots: [String], base: URL) -> (accepted: [(name: String, url: URL)], rejected: [String]) {
        if roots.isEmpty { return ([("", base)], []) }
        var accepted: [(name: String, url: URL)] = []
        var rejected: [String] = []
        for root in roots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                rejected.append(trimmed)
                continue
            }
            let url = base.appendingPathComponent(trimmed)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if contains(base, url) {
                accepted.append((trimmed, url))
            } else {
                rejected.append(trimmed)
            }
        }
        return (accepted, rejected)
    }
}

struct KnowledgeSection: Sendable, Equatable {
    var title: String
    var text: String
    var links: [String]
}

/// Splits notes into heading-scoped sections so a hit is the part of a note that matched.
enum KnowledgeMarkdown {
    static func stripFrontmatter(_ raw: String) -> (body: String, title: String?) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return (text, nil) }
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        let searchFrom = text.index(text.startIndex, offsetBy: 3)
        guard let close = text.range(of: "\n---", range: searchFrom..<text.endIndex) else { return (text, nil) }
        let after = close.upperBound
        if after < text.endIndex, text[after] != "\n" { return (text, nil) }
        let front = close.lowerBound >= afterOpen ? String(text[afterOpen..<close.lowerBound]) : ""
        var title: String?
        for line in front.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("title:") else { continue }
            let value = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { title = value }
            break
        }
        let bodyStart = after < text.endIndex ? text.index(after: after) : text.endIndex
        return (String(text[bodyStart...]), title)
    }

    static func sections(fileTitle: String, body: String, markdown: Bool, maxChars: Int) -> [KnowledgeSection] {
        var stack: [(level: Int, text: String)] = []
        var buffer: [String] = []
        var inFence = false
        var out: [KnowledgeSection] = []

        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = []
            guard !text.isEmpty else { return }
            let title = ([fileTitle] + stack.map(\.text)).joined(separator: " › ")
            for piece in split(text, maxChars: maxChars) {
                out.append(KnowledgeSection(title: title, text: piece, links: wikilinks(in: piece)))
            }
        }

        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if markdown, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                buffer.append(raw)
                continue
            }
            if markdown, !inFence, let heading = heading(trimmed) {
                flush()
                while let last = stack.last, last.level >= heading.level { stack.removeLast() }
                stack.append(heading)
                continue
            }
            buffer.append(raw)
        }
        flush()
        return out
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), line.count > level else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    static func split(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var pieces: [String] = []
        var current = ""
        func push() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > maxChars {
                push()
                var rest = Substring(paragraph)
                while rest.count > maxChars {
                    let cut = rest.index(rest.startIndex, offsetBy: maxChars)
                    pieces.append(String(rest[..<cut]))
                    rest = rest[cut...]
                }
                current = String(rest)
            } else if current.count + paragraph.count + 2 > maxChars {
                push()
                current = paragraph
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        push()
        return pieces
    }

    /// `[[Note]]`, `[[Note|alias]]`, `[[Folder/Note#Heading]]` → lowercased note names.
    static func wikilinks(in text: String) -> [String] {
        var links: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            var inner = String(after[..<close.lowerBound])
            rest = after[close.upperBound...]
            if inner.contains("\n") { continue }
            if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
            if let hash = inner.firstIndex(of: "#") { inner = String(inner[..<hash]) }
            var name = (inner.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent.lowercased()
            if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
            if !name.isEmpty, !links.contains(name) { links.append(name) }
        }
        return links
    }
}
