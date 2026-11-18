import Foundation

/// An external coding agent GrizzyBot can hand a job to over ACP.
public struct ExternalAgentSpec: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Executable followed by its arguments.
    public var command: [String]

    public init(id: String, name: String, command: [String]) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// Built in. Settings adds custom ones beside these.
    public static let presets: [ExternalAgentSpec] = [
        ExternalAgentSpec(id: "opencode", name: "opencode", command: ["opencode", "acp"]),
    ]

    /// Built-in agents first, then the ones the person added.
    public static func all(custom: [ExternalAgentSpec]) -> [ExternalAgentSpec] { presets + custom }

    public static func isPreset(_ id: String) -> Bool { presets.contains { $0.id == id } }

    /// An agent by id or name, case-insensitively. Empty means the first built-in agent.
    public static func named(_ id: String, custom: [ExternalAgentSpec] = []) -> ExternalAgentSpec? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return presets.first }
        return all(custom: custom).first { $0.id.lowercased() == key || $0.name.lowercased() == key }
    }

    /// A lowercase id from a display name, never one a built-in agent already uses.
    public static func makeId(from name: String, existing: [ExternalAgentSpec]) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let root = base.isEmpty ? "agent" : base
        let taken = Set(all(custom: existing).map(\.id))
        if !taken.contains(root) { return root }
        var n = 2
        while taken.contains("\(root)-\(n)") { n += 1 }
        return "\(root)-\(n)"
    }

    /// Splits a command line into words, honouring single and double quotes and backslash escapes.
    /// Nothing is run through a shell; this only decides where one argument ends.
    public static func parseCommandLine(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else {
                current.append(ch); started = true
            }
        }
        if started { words.append(current) }
        return words
    }

    /// Why a command line cannot be used, or nil when it can.
    public static func commandProblem(_ command: [String]) -> String? {
        guard let first = command.first, !first.isEmpty else { return "Enter the command that starts the agent." }
        if first.contains("=") && !first.hasPrefix("/") { return "Start with the program name, not VAR=value." }
        return nil
    }
}

/// How much an external agent may do inside the working folder.
public enum ExternalAgentAccess: String, Sendable {
    case read
    case edit

    public static func parse(_ raw: String) -> ExternalAgentAccess {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "edit" ? .edit : .read
    }
}

/// Decides each permission request an external agent raises mid-run. The person approved the job and
/// its access level up front; this keeps the agent inside that. Running commands, deleting and moving
/// files are never allowed, and anything the agent does not label is refused.
public enum AcpPermissionPolicy {
    public static func allows(toolKind: String, access: ExternalAgentAccess) -> Bool {
        switch toolKind {
        case "read", "search", "think", "fetch": return true
        case "edit": return access == .edit
        default: return false
        }
    }

    /// The option id to answer with: an allow-once option when the request fits the access level,
    /// otherwise a reject option so the agent is told no. Nil cancels the request.
    public static func choose(_ request: AcpPermissionRequest, access: ExternalAgentAccess) -> String? {
        if allows(toolKind: request.toolKind, access: access),
           let allow = request.options.first(where: { $0.kind == "allow_once" }) {
            return allow.id
        }
        return request.options.first(where: { $0.kind == "reject_once" })?.id
            ?? request.options.first(where: { $0.kind == "reject_always" })?.id
    }
}

/// What the person needs to do when an agent's program is missing.
public enum ExternalAgentSetup {
    public static let opencodeNote = "OpenCode is not installed. Install it with `brew install sst/tap/opencode` or `npm i -g opencode-ai`, then run `opencode auth login`."

    /// True when the agent's program can be found (absolute path, or on PATH plus the usual install folders).
    public static func isInstalled(_ spec: ExternalAgentSpec) -> Bool {
        guard let first = spec.command.first, !first.isEmpty else { return false }
        let fm = FileManager.default
        if first.hasPrefix("/") { return fm.isExecutableFile(atPath: first) }
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.opencode/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.contains { fm.isExecutableFile(atPath: $0 + "/" + first) }
    }

    /// A setup note for a built-in agent whose program is missing, else nil.
    public static func note(for spec: ExternalAgentSpec) -> String? {
        spec.id == "opencode" && !isInstalled(spec) ? opencodeNote : nil
    }
}

/// Models LM Studio has loaded right now. OpenCode finds LM Studio on its own and names them `lmstudio/<id>`.
public enum LMStudioModels {
    public struct Loaded: Sendable, Equatable { public var id: String; public var contextLength: Int }

    public static func parse(_ data: Data) -> [Loaded] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, (item["state"] as? String) == "loaded" else { return nil }
            let type = item["type"] as? String
            guard type == nil || type == "llm" || type == "vlm" else { return nil }
            let ctx = (item["loaded_context_length"] as? Int) ?? (item["max_context_length"] as? Int) ?? 0
            return Loaded(id: id, contextLength: ctx)
        }
    }

    /// Empty when LM Studio is not running (2 second timeout).
    public static func loaded(base: String = "http://localhost:1234") async -> [Loaded] {
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v0/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    /// The OpenCode model value for a loaded model.
    public static func openCodeValue(_ m: Loaded) -> String { "lmstudio/" + m.id }
}
