import Foundation

/// A provider + model pair, used for fallbacks and for the cheap "light" model.
public struct ModelChoice: Codable, Sendable, Equatable, Hashable {
    public var provider: String
    public var modelId: String

    public init(provider: String, modelId: String) {
        self.provider = provider
        self.modelId = modelId
    }

    public var label: String { "\(provider)/\(modelId)" }
}

/// Decides which turns a small, cheap (or local) model can answer. Rule-based on purpose: it runs
/// before any model call, costs nothing, and its choice is always shown in the reply so a person can
/// tell which model answered and why.
public enum ModelRouter {
    public enum Verdict: Sendable, Equatable {
        case light(reason: String)
        case full(reason: String)

        public var isLight: Bool { if case .light = self { return true } else { return false } }
    }

    private static let workWords = try! NSRegularExpression(
        pattern: #"\b(write|build|create|research|analy[sz]e|search|find|look\s*up|compare|summari[sz]e|refactor|debug|fix|plan|draft|schedule|email|open|click|run|install|download|upload|file|folder|code|script|report|spreadsheet|calendar|book|buy|delete|remove|move|rename|deploy|commit|push)\b"#,
        options: [.caseInsensitive]
    )

    public static func route(
        prompt: String,
        hasImage: Bool,
        isCommand: Bool,
        hasLightModel: Bool,
        threadIsFresh: Bool = false
    ) -> Verdict {
        guard hasLightModel else { return .full(reason: "no light model set") }
        if isCommand { return .full(reason: "command or skill") }
        if hasImage { return .full(reason: "has an image") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 160 { return .full(reason: "long request") }
        if text.contains("\n") || text.contains("```") { return .full(reason: "multi-line request") }
        if text.lowercased().contains("http") { return .full(reason: "has a link") }
        let range = NSRange(text.startIndex..., in: text)
        if workWords.firstMatch(in: text, range: range) != nil { return .full(reason: "sounds like a task") }
        return .light(reason: "short conversational message")
    }
}

/// Which failures should send the run to the next model in the fallback chain.
public enum ModelFailover {
    public static func shouldFailover(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        return error is LLMError
    }

    /// A stream that died for a reason other than the provider rejecting the request is worth one
    /// plain, non-streaming retry on the same model first.
    public static func shouldRetryWithoutStreaming(_ error: Error) -> Bool {
        guard let llm = error as? LLMError else { return false }
        switch llm {
        case .decoding, .emptyResponse: return true
        default: return false
        }
    }
}

/// A command the person has said yes to for good, narrowed to what they actually approved.
///
/// `pattern` is matched against the approval's detail line (a shell command, a path, a host). `*`
/// matches anything; an empty pattern matches every use of the tool. A shell rule never matches a
/// command that chains or redirects, so approving `git status*` cannot approve `git status; rm -rf ~`.
public struct AllowRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var tool: String
    public var pattern: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, tool: String, pattern: String = "", createdAt: Date = .now) {
        self.id = id
        self.tool = tool
        self.pattern = pattern
        self.createdAt = createdAt
    }

    static let shellMetacharacters: [String] = [";", "&&", "||", "|", "`", "$(", "\n", ">", "<", "&"]

    public func matches(tool candidate: String, detail: String) -> Bool {
        guard candidate == tool else { return false }
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if candidate == "shell.exec" {
            if trimmed.isEmpty { return false } // a blanket shell rule is what autoApprove is for
            if Self.shellMetacharacters.contains(where: { detail.contains($0) }) { return false }
        }
        if trimmed.isEmpty { return true }
        return Self.glob(trimmed, detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `*`-only wildcard match over the whole string.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        if parts.count == 1 { return pattern == text }
        var rest = Substring(text)
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return rest.hasSuffix(part)
            } else {
                guard let found = rest.range(of: part) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        return true
    }

    /// A human-readable one-liner for Settings and the approval card.
    public var summary: String {
        pattern.isEmpty ? "\(tool) — anything" : "\(tool) — \(pattern)"
    }

    /// Whether the approval card may offer "Always allow". Not for the gates that exist to make sure a
    /// person looks every time.
    public static func alwaysAllowOffered(tool: String) -> Bool {
        !["memory.untrusted_write", "memory.untrusted_forget", "routine.untrusted", "secret.request"].contains(tool)
    }

    /// Tools where "always allow" should mean "this command / this folder", not "anything".
    public static func narrows(tool: String) -> Bool {
        tool == "shell.exec" || tool.hasSuffix(".host")
    }

    /// The narrowest rule that covers an approval: shell gets its first two words, a path gets its
    /// folder, anything else the exact detail.
    public static func suggested(tool: String, detail: String) -> AllowRule {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if tool == "shell.exec" {
            let words = text.split(separator: " ", omittingEmptySubsequences: true).prefix(2).joined(separator: " ")
            return AllowRule(tool: tool, pattern: words.isEmpty ? text : words + "*")
        }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let folder = (text as NSString).deletingLastPathComponent
            return AllowRule(tool: tool, pattern: folder.isEmpty ? text : folder + "/*")
        }
        return AllowRule(tool: tool, pattern: text)
    }
}
