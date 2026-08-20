import Foundation

public enum PolicyMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case enforce
    case dryRun = "dry-run"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .enforce: return "Enforce"
        case .dryRun: return "Dry run"
        }
    }
}

public enum PolicyIntent: String, Sendable, Codable {
    case activate
    case type
    case navigate
    case read
    case readFile = "read_file"
    case writeFile = "write_file"
    case listFiles = "list_files"
    case readTool = "read_tool"
    case writeTool = "write_tool"
}

public struct ActionPolicy: Codable, Sendable, Equatable {
    public var mode: PolicyMode
    /// Evaluated first. Any true expression refuses, whatever `allow` says.
    public var deny: [String]
    /// Any true expression permits. Empty means nothing is permitted.
    public var allow: [String]

    public init(mode: PolicyMode = .enforce, deny: [String] = [], allow: [String] = ["true"]) {
        self.mode = mode
        self.deny = deny
        self.allow = allow
    }

    /// Shipped default: permit everything, so an existing Mac is not locked out.
    public static let openDefault = ActionPolicy()

    public var isFailClosedEmpty: Bool {
        deny.isEmpty && allow.isEmpty
    }
}

public struct PolicyElement: Codable, Sendable, Equatable, Hashable {
    public var ref: String
    public var role: String
    public var name: String
    public var type: String?

    public init(ref: String, role: String, name: String, type: String? = nil) {
        self.ref = ref
        self.role = role
        self.name = name
        self.type = type
    }
}

public struct PolicyFile: Sendable, Equatable {
    public var path: String
    public var name: String
    public var fileExtension: String

    public init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        self.name = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
    }
}

public struct PolicyMcp: Sendable, Equatable {
    public var server: String
    public var tool: String
    public var effect: McpEffect

    public init(server: String, tool: String, effect: McpEffect) {
        self.server = server
        self.tool = tool
        self.effect = effect
    }
}

public struct PolicyContext: Sendable, Equatable {
    public var toolName: String
    public var botId: String
    public var actorId: String
    public var pageURL: String
    public var pageHost: String
    public var intent: PolicyIntent?
    public var key: String?
    public var element: PolicyElement?
    public var file: PolicyFile?
    public var mcp: PolicyMcp?

    public init(
        toolName: String,
        botId: String,
        actorId: String,
        pageURL: String = "",
        pageHost: String = "",
        intent: PolicyIntent? = nil,
        key: String? = nil,
        element: PolicyElement? = nil,
        file: PolicyFile? = nil,
        mcp: PolicyMcp? = nil
    ) {
        self.toolName = toolName
        self.botId = botId
        self.actorId = actorId
        self.pageURL = pageURL
        self.pageHost = pageHost
        self.intent = intent
        self.key = key
        self.element = element
        self.file = file
        self.mcp = mcp
    }

    func celValues() -> [String: PolicyCEL.Value] {
        var root: [String: PolicyCEL.Value] = [
            "tool": .object(["name": .string(toolName)]),
            "bot": .object(["id": .string(botId)]),
            "actor": .object(["id": .string(actorId)]),
            "page": .object([
                "url": .string(pageURL),
                "host": .string(pageHost),
            ]),
        ]
        if let intent {
            root["intent"] = .string(intent.rawValue)
        }
        if let key {
            root["key"] = .string(key)
        }
        if let element {
            var el: [String: PolicyCEL.Value] = [
                "ref": .string(element.ref),
                "role": .string(element.role),
                "name": .string(element.name),
            ]
            if let type = element.type {
                el["type"] = .string(type)
            }
            root["element"] = .object(el)
        }
        if let file {
            root["file"] = .object([
                "path": .string(file.path),
                "name": .string(file.name),
                "extension": .string(file.fileExtension),
            ])
        }
        if let mcp {
            root["mcp"] = .object([
                "server": .string(mcp.server),
                "tool": .string(mcp.tool),
                "effect": .string(mcp.effect.rawValue),
            ])
        }
        return root
    }
}

public struct PolicyDecision: Sendable, Equatable {
    public var allowed: Bool
    public var mode: PolicyMode
    public var matched: String?
    public var source: Source
    public var forward: Bool
    public var reason: String

    public enum Source: String, Sendable, Equatable {
        case deny
        case allow
        case `default`
    }

    public init(
        allowed: Bool,
        mode: PolicyMode,
        matched: String?,
        source: Source,
        forward: Bool,
        reason: String
    ) {
        self.allowed = allowed
        self.mode = mode
        self.matched = matched
        self.source = source
        self.forward = forward
        self.reason = reason
    }
}

/// CEL-style deny-before-allow, fail-closed. A missing policy permits nothing.
public enum ActionPolicyEngine {
    public static func evaluate(_ policy: ActionPolicy?, context: PolicyContext) -> PolicyDecision {
        let mode = policy?.mode ?? .enforce
        let deny = policy?.deny ?? []
        let allow = policy?.allow ?? []
        let values = context.celValues()

        for expression in deny {
            if matches(expression, values: values, onError: true) {
                return PolicyDecision(
                    allowed: false,
                    mode: mode,
                    matched: expression,
                    source: .deny,
                    forward: mode == .dryRun,
                    reason: describeRefusal(context, expression: expression)
                )
            }
        }

        for expression in allow {
            if matches(expression, values: values, onError: false) {
                return PolicyDecision(
                    allowed: true,
                    mode: mode,
                    matched: expression,
                    source: .allow,
                    forward: true,
                    reason: "Permitted by policy."
                )
            }
        }

        return PolicyDecision(
            allowed: false,
            mode: mode,
            matched: nil,
            source: .default,
            forward: mode == .dryRun,
            reason: "No rule in this workspace's policy permits that action, so it was refused."
        )
    }

    private static func matches(_ expression: String, values: [String: PolicyCEL.Value], onError: Bool) -> Bool {
        do {
            return try PolicyCEL.evaluate(expression, values: values) == true
        } catch {
            return onError
        }
    }

    private static func describeRefusal(_ context: PolicyContext, expression: String) -> String {
        if let file = context.file {
            return "This workspace's policy does not allow that: the file \(file.path) is blocked by the rule `\(expression)`."
        }
        if let mcp = context.mcp {
            return "This workspace's policy does not allow that: MCP \(mcp.server)/\(mcp.tool) is blocked by the rule `\(expression)`."
        }
        let what = context.element?.name.isEmpty == false
            ? "“\(context.element!.name)”"
            : "a \(context.toolName) action"
        let host = context.pageHost.isEmpty ? "this Mac" : context.pageHost
        return "This workspace's policy does not allow that: \(what) on \(host) is blocked by the rule `\(expression)`."
    }
}
