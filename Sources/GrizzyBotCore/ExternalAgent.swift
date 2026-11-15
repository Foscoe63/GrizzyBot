import Foundation

/// An external coding agent GrizzyBot can hand a job to over ACP.
public struct ExternalAgentSpec: Sendable, Equatable {
    public var id: String
    public var name: String
    /// Executable followed by its arguments.
    public var command: [String]

    public init(id: String, name: String, command: [String]) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// Built in for now; a settings screen for custom agents comes later.
    public static let presets: [ExternalAgentSpec] = [
        ExternalAgentSpec(id: "opencode", name: "opencode", command: ["opencode", "acp"]),
    ]

    public static func named(_ id: String) -> ExternalAgentSpec? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? presets.first : presets.first { $0.id == key }
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
