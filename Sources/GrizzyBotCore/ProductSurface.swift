import Foundation

// MARK: - Chat search

public struct ChatSearchHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(threadKey):\(messageId)" }
    public var botId: String?
    public var groupId: String?
    public var botName: String
    public var threadKey: String
    public var messageId: String
    public var snippet: String
    public var role: MessageRole

    public init(
        botId: String?,
        groupId: String?,
        botName: String,
        threadKey: String,
        messageId: String,
        snippet: String,
        role: MessageRole
    ) {
        self.botId = botId
        self.groupId = groupId
        self.botName = botName
        self.threadKey = threadKey
        self.messageId = messageId
        self.snippet = snippet
        self.role = role
    }
}

public enum ChatSearch {
    public enum Scope: Sendable, Equatable {
        case all
        case thread(String)
    }

    public static func hits(
        query: String,
        bots: [Bot],
        groups: [GroupRoom],
        threads: [String: ThreadData],
        scope: Scope
    ) -> [ChatSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        let folded = needle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var results: [ChatSearchHit] = []

        func consider(threadKey: String, botId: String?, groupId: String?, name: String) {
            if case .thread(let key) = scope, key != threadKey { return }
            guard let thread = threads[threadKey] else { return }
            for message in thread.messages {
                let text = message.firstText
                let hay = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                guard hay.contains(folded) else { continue }
                results.append(
                    ChatSearchHit(
                        botId: botId,
                        groupId: groupId,
                        botName: name,
                        threadKey: threadKey,
                        messageId: message.id,
                        snippet: snippet(text, around: needle),
                        role: message.role
                    )
                )
            }
        }

        for bot in bots {
            consider(threadKey: bot.id, botId: bot.id, groupId: nil, name: bot.name)
            for task in bot.tasks {
                consider(threadKey: task.id, botId: bot.id, groupId: nil, name: "\(bot.name) · \(task.title)")
            }
        }
        for group in groups {
            consider(threadKey: group.id, botId: nil, groupId: group.id, name: group.name)
        }
        return results
    }

    public static func snippet(_ text: String, around query: String, radius: Int = 72) -> String {
        let hay = text as NSString
        let range = hay.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound else {
            return text.count <= radius * 2 ? text : String(text.prefix(radius * 2)) + "…"
        }
        let start = max(0, range.location - radius)
        let end = min(hay.length, range.location + range.length + radius)
        var slice = hay.substring(with: NSRange(location: start, length: end - start))
        if start > 0 { slice = "…" + slice }
        if end < hay.length { slice += "…" }
        return slice.replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Paste / vault dump guard

public enum PasteGuard {
    public static let warnCharacterCount = 8_000
    public static let localModelCharacterCount = 6_000

    public static func warning(for text: String, localModel: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.components(separatedBy: .newlines)
        let wikiLinks = trimmed.components(separatedBy: "[[").count - 1
        let looksLikeVault =
            wikiLinks >= 8
            || (trimmed.localizedCaseInsensitiveContains("obsidian") && lines.count >= 40)
            || (lines.count >= 80 && trimmed.contains("/"))
        let limit = localModel ? localModelCharacterCount : warnCharacterCount
        if looksLikeVault || trimmed.count >= limit {
            return "This paste looks like a vault listing or is too large to send to a local model. Use mcp_call / list tools instead of pasting the vault into chat."
        }
        return nil
    }
}

// MARK: - Composer keys (Return sends)

public enum ComposerKeys {
    public static func shouldSend(shiftHeld: Bool, text: String) -> Bool {
        !shiftHeld && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Plugin catalog filter (Plugins overlay)

public enum PluginCatalogFilter {
    public static func matches(_ item: ConnectionItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return item.name.lowercased().contains(q)
            || item.slug.lowercased().contains(q)
            || item.blurb.lowercased().contains(q)
    }

    public static func filter(_ items: [ConnectionItem], query: String) -> [ConnectionItem] {
        items.filter { matches($0, query: query) }
    }
}

// MARK: - Secrets: keep / set / clear

public enum AppSecret: String, Sendable, CaseIterable {
    case composioConnect
    case composioApi
    case box
    case tts
    case sentry
}

public enum SecretFieldUpdate {
    /// Empty input keeps the stored value. Non-empty replaces it.
    public static func applying(current: String?, input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return current }
        return trimmed
    }
}

extension AppConfig {
    public mutating func applySecret(_ secret: AppSecret, input: String) {
        let next = SecretFieldUpdate.applying(current: stored(secret), input: input)
        set(secret, next)
    }

    public mutating func clearSecret(_ secret: AppSecret) {
        set(secret, nil)
    }

    public func stored(_ secret: AppSecret) -> String? {
        switch secret {
        case .composioConnect: return composioConnectKey
        case .composioApi: return composioApiKey
        case .box: return boxToken
        case .tts: return ttsKey
        case .sentry: return sentryDSN
        }
    }

    private mutating func set(_ secret: AppSecret, _ value: String?) {
        switch secret {
        case .composioConnect: composioConnectKey = value
        case .composioApi: composioApiKey = value
        case .box: boxToken = value
        case .tts: ttsKey = value
        case .sentry: sentryDSN = value
        }
    }
}

// MARK: - Bot capabilities (chat banner)

public struct BotCapabilitySummary: Sendable, Equatable {
    public var shellEnabled: Bool
    public var computerEnabled: Bool

    public var banner: String? {
        switch (shellEnabled, computerEnabled) {
        case (true, true): return nil
        case (false, false):
            return "This bot cannot use Shell or Computer. Enable them in the bot’s Tools settings."
        case (false, true):
            return "This bot cannot use Shell. Enable Shell in the bot’s Tools settings."
        case (true, false):
            return "This bot cannot use Computer. Enable screenshot / click tools in the bot’s Tools settings."
        }
    }

    public static func of(_ bot: Bot) -> BotCapabilitySummary {
        BotCapabilitySummary(
            shellEnabled: bot.isToolEnabled("shell"),
            computerEnabled: bot.isToolEnabled("computer_screenshot")
                || bot.isToolEnabled("request_takeover")
                || bot.enabledTools.contains(where: { $0.hasPrefix("computer_") })
        )
    }
}

public enum BotModelChoice: Sendable, Hashable, Identifiable, CustomStringConvertible {
    case workspaceDefault
    case catalog(provider: String, modelId: String, label: String)

    public var id: String {
        switch self {
        case .workspaceDefault: return "workspace-default"
        case .catalog(let provider, let modelId, _): return "\(provider)::\(modelId)"
        }
    }

    public var description: String {
        switch self {
        case .workspaceDefault: return "Workspace default"
        case .catalog(_, _, let label): return label
        }
    }

    public static func choices(workspaceModel: String?) -> [BotModelChoice] {
        var list: [BotModelChoice] = [.workspaceDefault]
        var seen = Set<String>()
        for entry in ModelCatalog.entries {
            let choice = BotModelChoice.catalog(
                provider: entry.provider,
                modelId: entry.id,
                label: "\(entry.providerName ?? entry.provider) · \(entry.label)"
            )
            if seen.insert(choice.id).inserted {
                list.append(choice)
            }
        }
        _ = workspaceModel
        return list
    }

    public static func current(bot: Bot) -> BotModelChoice {
        guard let provider = bot.modelProvider, let modelId = bot.modelId, !modelId.isEmpty else {
            return .workspaceDefault
        }
        if let entry = ModelCatalog.entries.first(where: { $0.provider == provider && $0.id == modelId }) {
            return .catalog(
                provider: provider,
                modelId: modelId,
                label: "\(entry.providerName ?? entry.provider) · \(entry.label)"
            )
        }
        return .catalog(provider: provider, modelId: modelId, label: modelId)
    }
}

extension ModelCatalog {
    public static var deviceCodeProviders: [CatalogEntry] {
        providers.filter { $0.signIn == .deviceCode }
    }
}

// MARK: - Run diagnostics

public struct RunLogLine: Sendable, Equatable {
    public var at: Date
    public var botId: String
    public var kind: String
    public var text: String

    public init(at: Date = .now, botId: String, kind: String, text: String) {
        self.at = at
        self.botId = botId
        self.kind = kind
        self.text = text
    }

    public var formatted: String {
        let stamp = at.formatted(date: .omitted, time: .standard)
        return "[\(stamp)] \(kind) \(botId): \(text)"
    }
}

public enum RunLog {
    public static let maxLines = 400

    public static func appending(_ lines: [RunLogLine], botId: String, kind: String, text: String) -> [RunLogLine] {
        var next = lines
        next.append(RunLogLine(botId: botId, kind: kind, text: String(text.prefix(4_000))))
        if next.count > maxLines {
            next.removeFirst(next.count - maxLines)
        }
        return next
    }

    public static func dump(_ lines: [RunLogLine]) -> String {
        if lines.isEmpty { return "No tool or MCP activity recorded in this session yet." }
        return lines.suffix(200).map(\.formatted).joined(separator: "\n")
    }
}

// MARK: - Sparkle appcast

public struct AppcastItem: Sendable, Equatable {
    public var title: String
    public var version: String
    public var shortVersion: String
    public var pubDate: String
    public var enclosureURL: String
    public var edSignature: String
    public var length: Int
    public var minimumSystemVersion: String
    public var notesHTML: String

    public init(
        title: String,
        version: String,
        shortVersion: String,
        pubDate: String,
        enclosureURL: String,
        edSignature: String,
        length: Int,
        minimumSystemVersion: String = "15.0",
        notesHTML: String = ""
    ) {
        self.title = title
        self.version = version
        self.shortVersion = shortVersion
        self.pubDate = pubDate
        self.enclosureURL = enclosureURL
        self.edSignature = edSignature
        self.length = length
        self.minimumSystemVersion = minimumSystemVersion
        self.notesHTML = notesHTML
    }

    public var xmlFragment: String {
        let notes = notesHTML.isEmpty ? "<p>GrizzyBot \(shortVersion)</p>" : notesHTML
        return """
            <item>
              <title>\(title)</title>
              <pubDate>\(pubDate)</pubDate>
              <sparkle:version>\(version)</sparkle:version>
              <sparkle:shortVersionString>\(shortVersion)</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>\(minimumSystemVersion)</sparkle:minimumSystemVersion>
              <description><![CDATA[\(notes)]]></description>
              <enclosure url="\(enclosureURL)"
                         type="application/octet-stream"
                         sparkle:edSignature="\(edSignature)"
                         length="\(length)" />
            </item>
        """
    }
}

public enum AppcastXML {
    public static func inserting(_ item: AppcastItem, into xml: String) throws -> String {
        var next = removingItem(version: item.version, from: xml)
        guard let channel = next.range(of: "<channel>") else {
            throw AppcastXMLError.missingChannel
        }
        next.insert(contentsOf: "\n" + item.xmlFragment, at: channel.upperBound)
        return next
    }

    public static func buildNumbers(in xml: String) -> [String] {
        buildNumberRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }
    }

    public static func removingItem(version: String, from xml: String) -> String {
        var result = xml
        let pattern = "<item>[\\s\\S]*?<sparkle:version>\(NSRegularExpression.escapedPattern(for: version))</sparkle:version>[\\s\\S]*?</item>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private static let buildNumberRegex = try! NSRegularExpression(
        pattern: "<sparkle:version>([^<]+)</sparkle:version>",
        options: []
    )
}

public enum AppcastXMLError: Error, Sendable {
    case missingChannel
}

// MARK: - Workspace backup (iCloud container, then iCloud Drive, then Documents)

public enum WorkspaceBackup {
    public static let ubiquityContainerIdentifier = "iCloud.com.grizzybot.app"

    public static func iCloudDriveURL(fileManager: FileManager = .default, home: URL? = nil) -> URL? {
        let homeURL = home ?? fileManager.homeDirectoryForCurrentUser
        let url = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    public static func backupDirectory(
        fileManager: FileManager = .default,
        home: URL? = nil,
        ubiquityContainer: URL? = nil,
        resolveUbiquity: Bool = true
    ) -> URL {
        let container: URL? = {
            if let ubiquityContainer { return ubiquityContainer }
            guard resolveUbiquity else { return nil }
            return fileManager.url(forUbiquityContainerIdentifier: ubiquityContainerIdentifier)
        }()
        if let container {
            let dir = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let iCloud = iCloudDriveURL(fileManager: fileManager, home: home) {
            let dir = iCloud.appendingPathComponent("GrizzyBot Backups", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let documents = home.map {
            $0.appendingPathComponent("Documents", isDirectory: true)
        } ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("GrizzyBot Backups", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func filename(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "grizzybot-backup-\(formatter.string(from: now)).json"
    }
}

// MARK: - ElevenLabs TTS

public enum ElevenLabsTTS {
    public static let defaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    public static func voiceId(named name: String?) -> String {
        let key = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "", "rachel": return defaultVoiceId
        case "adam": return "pNInz6obpgDQGcFmaJgB"
        case "bella": return "EXAVITQu4vr4xnSDxMaL"
        case "antoni": return "ErXwobaYiN019PkySvjV"
        case "elli": return "MF3mGyEYCl7XYWbV9V6O"
        case "josh": return "TxGEqnHWrfWFTfGW9XjX"
        case "arnold": return "VR6AewLTigWG4xSOukaG"
        default:
            if key.count >= 16, key.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return name ?? defaultVoiceId
            }
            return defaultVoiceId
        }
    }

    public static func request(text: String, apiKey: String, voiceName: String?) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ElevenLabsError.missingKey }
        let voice = voiceId(named: voiceName)
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)") else {
            throw ElevenLabsError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": String(text.prefix(4_000)),
            "model_id": "eleven_monolingual_v1",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public enum ElevenLabsError: Error, LocalizedError, Sendable {
    case missingKey
    case badURL
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "ElevenLabs API key is missing."
        case .badURL: return "ElevenLabs URL was invalid."
        case .http(let code, let body): return "ElevenLabs HTTP \(code): \(body.prefix(180))"
        }
    }
}

extension AgentLoopRequest {
    public static func charBudget(provider: String?) -> Int {
        LocalProviders.isLocal(provider ?? "") ? 24_000 : 80_000
    }
}
