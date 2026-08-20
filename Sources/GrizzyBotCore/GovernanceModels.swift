import Foundation

public enum AccountRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case owner
    case operatorUser = "operator"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .owner: return "Owner"
        case .operatorUser: return "Operator"
        }
    }
}

public enum BotVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case `private`
    case shared

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .private: return "Private"
        case .shared: return "Shared"
        }
    }
}

public enum BotRuntime: String, Codable, Sendable, CaseIterable, Identifiable {
    case local
    case agui

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: return "GrizzyBot loop"
        case .agui: return "AG-UI endpoint"
        }
    }
}

/// Machine-level policy, grants, knowledge, and published components. Shared across Mac accounts.
public struct GovernanceBundle: Codable, Sendable, Equatable {
    public var actionPolicy: ActionPolicy
    public var pluginGrants: [PluginGrant]
    public var knowledgeSources: [KnowledgeSource]
    public var sandboxComponents: [SandboxComponent]
    public var mcpAdvertisedTools: [String: [String]]

    public init(
        actionPolicy: ActionPolicy = .openDefault,
        pluginGrants: [PluginGrant] = [],
        knowledgeSources: [KnowledgeSource] = [],
        sandboxComponents: [SandboxComponent] = [],
        mcpAdvertisedTools: [String: [String]] = [:]
    ) {
        self.actionPolicy = actionPolicy
        self.pluginGrants = pluginGrants
        self.knowledgeSources = knowledgeSources
        self.sandboxComponents = sandboxComponents
        self.mcpAdvertisedTools = mcpAdvertisedTools
    }
}
