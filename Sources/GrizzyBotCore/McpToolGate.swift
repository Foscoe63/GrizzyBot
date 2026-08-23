import Foundation

/// Live connection probe for an MCP server (session-only; not persisted).
public enum McpProbeStatus: Equatable, Sendable {
    case idle
    case checking
    case connected(toolCount: Int)
    case failed(String)
}

/// Per-tool enablement for MCP servers.
///
/// Parent id `mcp:<serverId>` still means the server is on. Child ids
/// `mcp:<serverId>/<toolName>` gate individual advertised tools.
/// If no child ids are recorded, every advertised tool is treated as on (legacy).
public enum McpToolGate {
    public static func childId(serverId: String, toolName: String) -> String {
        "mcp:\(serverId)/\(toolName)"
    }

    public static func parse(_ toolId: String) -> (serverId: String, toolName: String)? {
        guard toolId.hasPrefix("mcp:") else { return nil }
        let rest = toolId.dropFirst(4)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let serverId = String(rest[..<slash])
        let toolName = String(rest[rest.index(after: slash)...])
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }

    public static func isChildId(_ toolId: String) -> Bool {
        parse(toolId) != nil
    }

    public static func childPrefix(serverId: String) -> String {
        "mcp:\(serverId)/"
    }

    public static func hasChildToggles(enabledIds: [String], serverId: String) -> Bool {
        let prefix = childPrefix(serverId: serverId)
        return enabledIds.contains { $0.hasPrefix(prefix) }
    }

    /// Parent must be on. With no child toggles, all tools are on.
    /// Advertised names that have been turned off are denied. Names not yet in
    /// `advertised` (e.g. a Toolport catalog hit) stay allowed until listed.
    public static func isToolEnabled(
        enabledIds: [String],
        serverId: String,
        toolName: String,
        advertised: [String] = []
    ) -> Bool {
        guard enabledIds.contains("mcp:\(serverId)") else { return false }
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if !hasChildToggles(enabledIds: enabledIds, serverId: serverId) { return true }
        if enabledIds.contains(childId(serverId: serverId, toolName: trimmed)) { return true }
        if advertised.contains(trimmed) { return false }
        return true
    }

    /// First per-tool change materializes every advertised sibling as enabled
    /// so legacy "all on" does not collapse to a single toggle.
    public static func setChild(
        enabledIds: inout [String],
        serverId: String,
        toolName: String,
        enabled: Bool,
        advertised: [String]
    ) {
        let parent = "mcp:\(serverId)"
        let prefix = childPrefix(serverId: serverId)
        let child = childId(serverId: serverId, toolName: toolName)
        if !enabledIds.contains(where: { $0.hasPrefix(prefix) }) {
            for name in advertised {
                let id = childId(serverId: serverId, toolName: name)
                if name == toolName {
                    if enabled, !enabledIds.contains(id) { enabledIds.append(id) }
                } else if !enabledIds.contains(id) {
                    enabledIds.append(id)
                }
            }
            if enabled, !advertised.contains(toolName), !enabledIds.contains(child) {
                enabledIds.append(child)
            }
        } else if enabled {
            if !enabledIds.contains(child) { enabledIds.append(child) }
        } else {
            enabledIds.removeAll { $0 == child }
        }
        if enabled, !enabledIds.contains(parent) {
            enabledIds.append(parent)
        }
    }

    public static func stripServer(_ serverId: String, from ids: inout [String]) {
        let parent = "mcp:\(serverId)"
        let prefix = childPrefix(serverId: serverId)
        ids.removeAll { $0 == parent || $0.hasPrefix(prefix) }
    }

    public static func childIds(serverId: String, names: [String]) -> [String] {
        names.map { childId(serverId: serverId, toolName: $0) }
    }
}
