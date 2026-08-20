import Foundation

public enum AuditEventType: String, Codable, Sendable {
    case configurationChanged = "configuration.changed"
    case credentialCreated = "credential.created"
    case credentialRotated = "credential.rotated"
    case credentialRevoked = "credential.revoked"
    case knowledgeSearched = "knowledge.searched"
    case agentInvoked = "agent.invoked"
    case agentStreamStalled = "agent.stream_stalled"
    case mcpCallSucceeded = "mcp.call_succeeded"
    case mcpCallRejected = "mcp.call_rejected"
    case computerActionAllowed = "computer.action_allowed"
    case computerActionRefused = "computer.action_refused"
    case computerActionFailed = "computer.action_failed"
    case computerHelpRequested = "computer.help_requested"
    case computerControlTaken = "computer.control_taken"
    case computerControlReleased = "computer.control_released"
    case computerSecretRequested = "computer.secret_requested"
    case computerSecretSupplied = "computer.secret_supplied"
    case computerPolicyLoaded = "computer.policy_loaded"
    case computerIsolationLoaded = "computer.isolation_loaded"
    case botDeclined = "bot.declined"
    case componentInvoked = "component.invoked"
    case componentRefused = "component.refused"
    case connectorSyncSucceeded = "connector.sync_succeeded"
    case connectorSyncFailed = "connector.sync_failed"
}

public struct AuditEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: AuditEventType
    public var at: Date
    public var actorId: String
    public var botId: String?
    public var tool: String?
    public var matched: String?
    public var source: String?
    public var allowed: Bool?
    public var forwarded: Bool?
    public var reason: String
    /// Redacted attributes. Secrets are `{ "chars": N }` only.
    public var attributes: [String: JSONValue]

    public init(
        id: String = Ids.new(),
        type: AuditEventType,
        at: Date = .now,
        actorId: String,
        botId: String? = nil,
        tool: String? = nil,
        matched: String? = nil,
        source: String? = nil,
        allowed: Bool? = nil,
        forwarded: Bool? = nil,
        reason: String,
        attributes: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.at = at
        self.actorId = actorId
        self.botId = botId
        self.tool = tool
        self.matched = matched
        self.source = source
        self.allowed = allowed
        self.forwarded = forwarded
        self.reason = reason
        self.attributes = AuditRedactor.redact(attributes)
    }
}

public enum AuditRedactor {
    private static let sensitiveKeys: Set<String> = [
        "access_token", "accesstoken", "api_key", "apikey", "authorization",
        "client_secret", "clientsecret", "content", "credential", "credentials",
        "document_content", "documentcontent", "encrypted_value", "encryptedvalue",
        "id_token", "idtoken", "password", "prompt", "refresh_token", "refreshtoken",
        "result", "secret", "secrets", "token", "tokens", "tool_arguments", "tool_result",
        "text", "body", "value",
    ]

    public static func redact(_ attributes: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in attributes {
            out[key] = redact(key: key, value: value)
        }
        return out
    }

    public static func secretRecord(label: String, characterCount: Int) -> [String: JSONValue] {
        [
            "label": .string(label),
            "chars": .number(Double(characterCount)),
        ]
    }

    private static func redact(key: String, value: JSONValue) -> JSONValue {
        let folded = key.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        let sensitive = sensitiveKeys.contains(key.lowercased())
            || sensitiveKeys.contains(folded)
        switch value {
        case .string(let text):
            if sensitive {
                return .object(["chars": .number(Double(text.count))])
            }
            return .string(DiagnosticScrubber.redact(text))
        case .object(let object):
            var nested: [String: JSONValue] = [:]
            for (nestedKey, nestedValue) in object {
                nested[nestedKey] = redact(key: nestedKey, value: nestedValue)
            }
            return .object(nested)
        case .array(let items):
            return .array(items.map { redact(key: key, value: $0) })
        default:
            return value
        }
    }
}

public enum AuditLog {
    public static let cap = 2_000

    public static func appending(_ events: [AuditEvent], _ event: AuditEvent) -> [AuditEvent] {
        var next = events
        next.append(event)
        if next.count > cap {
            next = Array(next.suffix(cap))
        }
        return next
    }

    public static func recent(_ events: [AuditEvent], limit: Int = 40, botId: String? = nil) -> [AuditEvent] {
        let filtered: [AuditEvent]
        if let botId {
            filtered = events.filter { $0.botId == botId }
        } else {
            filtered = events
        }
        return Array(filtered.reversed().prefix(limit))
    }

    public static func refusals(_ events: [AuditEvent], botId: String?, limit: Int = 12) -> [AuditEvent] {
        recent(events, limit: 200, botId: botId)
            .filter { $0.allowed == false || $0.type == .computerActionRefused || $0.type == .mcpCallRejected }
            .prefix(limit)
            .map { $0 }
    }

    public struct Query: Sendable, Equatable {
        public var type: AuditEventType?
        public var botId: String?
        public var allowed: Bool?
        public var text: String
        public var limit: Int

        public init(
            type: AuditEventType? = nil,
            botId: String? = nil,
            allowed: Bool? = nil,
            text: String = "",
            limit: Int = 40
        ) {
            self.type = type
            self.botId = botId
            self.allowed = allowed
            self.text = text
            self.limit = limit
        }
    }

    public static func query(_ events: [AuditEvent], _ query: Query) -> [AuditEvent] {
        let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = events.filter { event in
            if let type = query.type, event.type != type { return false }
            if let botId = query.botId, event.botId != botId { return false }
            if let allowed = query.allowed, event.allowed != allowed { return false }
            if !needle.isEmpty {
                let hay = [
                    event.type.rawValue,
                    event.reason,
                    event.tool ?? "",
                    event.botId ?? "",
                    event.actorId,
                    event.matched ?? "",
                    event.source ?? "",
                ].joined(separator: " ").lowercased()
                if !hay.contains(needle) { return false }
            }
            return true
        }
        return Array(filtered.reversed().prefix(max(1, query.limit)))
    }
}
