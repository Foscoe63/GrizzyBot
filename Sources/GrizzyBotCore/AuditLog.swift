import CryptoKit
import Foundation

public enum AuditEventType: String, Codable, Sendable {
    case configurationChanged = "configuration.changed"
    case credentialCreated = "credential.created"
    case credentialRotated = "credential.rotated"
    case credentialRevoked = "credential.revoked"
    case knowledgeSearched = "knowledge.searched"
    case agentInvoked = "agent.invoked"
    case agentStreamStalled = "agent.stream_stalled"
    case routineWebhook = "routine.webhook"
    case channelMessage = "channel.message"
    case channelPairing = "channel.pairing"
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
    /// Links this event to the one before it (see `AuditChain`). Nil on events saved before chaining.
    public var chain: String?

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

/// Each event carries a hash of its own content plus the previous event's hash, so deleting, reordering,
/// or editing an event in the middle of the log breaks every link after it. This catches casual or
/// accidental changes to `audit.json`; someone who can rewrite the whole file can also rewrite the chain.
public enum AuditChain {
    public struct Verification: Equatable, Sendable {
        public var checked: Int
        /// Events saved before chaining existed; they are skipped, not failed.
        public var unchained: Int
        /// Index of the first event whose link does not hold, if any.
        public var brokenAt: Int?
        public var intact: Bool { brokenAt == nil }

        public var summary: String {
            if let brokenAt { return "Audit trail broken at event \(brokenAt + 1): its contents or position changed after it was recorded." }
            if checked == 0 { return "No chained events yet." }
            return "Audit trail intact — \(checked) event\(checked == 1 ? "" : "s") verified."
        }
    }

    static func digest(_ event: AuditEvent, previous: String) -> String {
        var parts: [String] = [
            previous, event.id, event.type.rawValue, String(Int(event.at.timeIntervalSince1970 * 1000)),
            event.actorId, event.botId ?? "", event.tool ?? "", event.matched ?? "", event.source ?? "",
            event.allowed.map { $0 ? "1" : "0" } ?? "", event.forwarded.map { $0 ? "1" : "0" } ?? "", event.reason,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        parts.append((try? encoder.encode(event.attributes)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        let hash = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func stamped(_ event: AuditEvent, after previous: AuditEvent?) -> AuditEvent {
        var copy = event
        copy.chain = digest(event, previous: previous?.chain ?? "genesis")
        return copy
    }

    public static func verify(_ events: [AuditEvent]) -> Verification {
        var checked = 0, unchained = 0
        var previous: String?
        for (index, event) in events.enumerated() {
            guard let chain = event.chain else { unchained += 1; previous = nil; continue }
            if let previous {
                if digest(event, previous: previous) != chain {
                    return Verification(checked: checked, unchained: unchained, brokenAt: index)
                }
                checked += 1
            } else if index == 0 || events[index - 1].chain == nil {
                // The first chained event after the log was trimmed or started: it anchors the chain.
                // It can still be checked against the genesis value when it is the true first event.
                if digest(event, previous: "genesis") == chain { checked += 1 }
            }
            previous = chain
        }
        return Verification(checked: checked, unchained: unchained, brokenAt: nil)
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
        next.append(AuditChain.stamped(event, after: events.last))
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
