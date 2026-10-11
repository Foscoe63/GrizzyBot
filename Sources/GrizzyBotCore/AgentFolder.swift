import Foundation

/// An agent folder as other tools ship them: a `SKILL.md` (at the top, or under `skills/<name>/`),
/// its `references/`, optionally `agents/*.yaml` with a display name, description, colour and icon,
/// and `.claude-plugin/plugin.json`. Reading one yields what a bot needs; nothing is copied here.
public struct AgentFolderManifest: Sendable, Equatable {
    public var folder: URL
    public var name: String
    public var summary: String
    public var brandColor: String?
    public var defaultPrompt: String?
    public var iconURL: URL?
    public var skillFile: URL
    public var skill: AgentSkill
}

public enum AgentFolderError: LocalizedError {
    case notAFolder
    case noSkill
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .notAFolder: return "That isn't a folder."
        case .noSkill: return "No SKILL.md found there, or under its skills/ folder, so there is no agent to import."
        case .tooLarge(let n): return "That folder has more than \(n) files; import a smaller one."
        }
    }
}

public enum AgentFolder {
    public static let maxFiles = 500
    public static let maxBytes = 20_000_000

    public static func read(_ folder: URL) throws -> AgentFolderManifest {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentFolderError.notAFolder
        }
        guard let skillFile = locateSkill(in: folder),
              let raw = try? String(contentsOf: skillFile, encoding: .utf8),
              let skill = try? SkillMarkdown.parse(
                raw, fallbackId: skillFile.deletingLastPathComponent().lastPathComponent, source: .user
              )
        else { throw AgentFolderError.noSkill }

        var yaml: [String: String] = [:]
        let agentsDir = folder.appendingPathComponent("agents", isDirectory: true)
        let yamlFiles = ((try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? [])
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }.sorted()
        if let first = yamlFiles.first,
           let text = try? String(contentsOf: agentsDir.appendingPathComponent(first), encoding: .utf8) {
            yaml = parseYAML(text)
        }
        var pluginName: String?
        var pluginDescription: String?
        let pluginFile = folder.appendingPathComponent(".claude-plugin/plugin.json")
        if let data = try? Data(contentsOf: pluginFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pluginName = object["name"] as? String
            pluginDescription = object["description"] as? String
        }

        let name = firstNonEmpty(yaml["display_name"], pluginName, skill.name, folder.lastPathComponent) ?? folder.lastPathComponent
        let summary = firstNonEmpty(yaml["short_description"], skill.description, pluginDescription) ?? ""
        let color = yaml["brand_color"].flatMap { BotAccent.rgb($0) != nil ? normalizedHex($0) : nil }
        let icon = [yaml["icon_large"], yaml["icon_small"]]
            .compactMap { $0 }
            .compactMap { resolve($0, in: folder) }
            .first { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        return AgentFolderManifest(
            folder: folder,
            name: name,
            summary: summary,
            brandColor: color,
            defaultPrompt: yaml["default_prompt"],
            iconURL: icon,
            skillFile: skillFile,
            skill: skill
        )
    }

    /// Every regular file worth copying (no `.git`, no `.DS_Store`, no symlinks), relative to `folder`.
    public static func files(in folder: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        var bytes = 0
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            bytes += values?.fileSize ?? 0
            out.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
            if out.count > maxFiles || bytes > maxBytes { throw AgentFolderError.tooLarge(maxFiles) }
        }
        // `.claude-plugin` is hidden but part of the package; the manifest has already been read.
        return out.sorted()
    }

    /// What the scanner makes of the skill and every Markdown file shipped with it.
    public static func scan(_ manifest: AgentFolderManifest) -> SkillScanReport {
        var findings = SkillScanner.scan(manifest.skill).findings
        let base = manifest.folder.standardizedFileURL
        for rel in (try? files(in: manifest.folder)) ?? [] where rel.hasSuffix(".md") && rel != "SKILL.md" {
            guard let text = try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8) else { continue }
            for finding in SkillScanner.scan(text: text).findings where !findings.contains(finding) {
                findings.append(finding)
            }
        }
        return SkillScanReport(findings: findings)
    }

    // MARK: - Parsing

    private static func locateSkill(in folder: URL) -> URL? {
        let fm = FileManager.default
        let top = folder.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: top.path) { return top }
        let skillsDir = folder.appendingPathComponent("skills", isDirectory: true)
        for name in ((try? fm.contentsOfDirectory(atPath: skillsDir.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let candidate = skillsDir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Flattens `key: value` lines at any indentation. Enough for the `interface:`/`policy:` shape
    /// these files use; not a YAML parser.
    public static func parseYAML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// A path from the manifest, kept inside the folder.
    private static func resolve(_ path: String, in folder: URL) -> URL? {
        var rel = path
        while rel.hasPrefix("./") { rel.removeFirst(2) }
        guard !rel.isEmpty, !rel.hasPrefix("/") else { return nil }
        let url = folder.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func normalizedHex(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
    }
}
