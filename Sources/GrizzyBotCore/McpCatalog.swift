import Foundation

public enum McpEffect: String, Codable, Sendable {
    case read
    case write
}

/// Fail-closed MCP effect: unknown or custom-server tools are writes.
public enum McpCatalog {
    public struct Entry: Sendable {
        public var key: String
        public var writeTools: Set<String>
        public var nameHints: [String]
        public var commandHints: [String]
    }

    public static let entries: [Entry] = [
        Entry(
            key: "github",
            writeTools: [
                "create_or_update_file", "create_repository", "fork_repository", "push_files",
                "create_issue", "update_issue", "add_issue_comment", "create_pull_request",
                "update_pull_request", "merge_pull_request", "create_pull_request_review",
                "add_pull_request_review_comment", "request_copilot_review", "create_gist",
                "update_gist", "delete_file", "create_branch", "update_pull_request_branch",
                "submit_pending_pull_request_review", "add_comment_to_pending_review",
                "delete_pending_pull_request_review", "create_or_update_issue",
            ],
            nameHints: ["github"],
            commandHints: ["github-mcp", "github_mcp"]
        ),
        Entry(
            key: "atlassian",
            writeTools: [
                "createJiraIssue", "editJiraIssue", "transitionJiraIssue", "addCommentToJiraIssue",
                "addWorklogToJiraIssue", "createConfluencePage", "updateConfluencePage",
                "createConfluenceFooterComment", "createConfluenceInlineComment",
            ],
            nameHints: ["atlassian", "jira", "confluence"],
            commandHints: ["atlassian"]
        ),
        Entry(
            key: "box",
            writeTools: [
                "copy_file", "copy_folder", "create_folder", "create_metadata_template",
                "get_upload_url", "move_file",
            ],
            nameHints: ["box"],
            commandHints: ["box"]
        ),
        Entry(
            key: "slack",
            writeTools: [
                "slack_send_message", "slack_send_message_draft", "slack_schedule_message",
                "slack_add_reaction", "slack_create_conversation", "slack_create_canvas",
                "slack_update_canvas",
            ],
            nameHints: ["slack"],
            commandHints: ["slack"]
        ),
        Entry(
            key: "salesforce",
            writeTools: ["create_record", "update_record", "delete_record"],
            nameHints: ["salesforce"],
            commandHints: ["salesforce"]
        ),
        Entry(
            key: "servicenow",
            writeTools: ["create_record", "update_record", "delete_record"],
            nameHints: ["servicenow"],
            commandHints: ["servicenow"]
        ),
    ]

    public static func entry(for server: McpServer) -> Entry? {
        let name = server.name.lowercased()
        let command = ([server.command] + server.args).joined(separator: " ").lowercased()
        let url = server.url.lowercased()
        return entries.first { entry in
            entry.nameHints.contains { name.contains($0) }
                || entry.commandHints.contains { command.contains($0) }
                || entry.nameHints.contains { url.contains($0) }
        }
    }

    /// Advertised + absent from the write list → read. Everything else is a write.
    public static func classify(
        server: McpServer?,
        toolName: String,
        advertised: Bool
    ) -> McpEffect {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .write }
        guard advertised else { return .write }
        guard let server, let entry = entry(for: server) else { return .write }
        return entry.writeTools.contains(trimmed) ? .write : .read
    }

    public static func classify(
        serverName: String,
        command: String,
        url: String,
        toolName: String,
        advertised: Bool
    ) -> McpEffect {
        let fake = McpServer(name: serverName, command: command, url: url)
        return classify(server: fake, toolName: toolName, advertised: advertised)
    }
}

public struct PluginGrant: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var botId: String
    /// `mcp:<serverId>` or `component:<id>` or a plugin slug.
    public var plugin: String
    /// Optional inner tool name. Nil means the whole plugin.
    public var tool: String?

    public init(id: String = Ids.new(), botId: String, plugin: String, tool: String? = nil) {
        self.id = id
        self.botId = botId
        self.plugin = plugin
        self.tool = tool
    }

    public static func allows(
        grants: [PluginGrant],
        botId: String,
        plugin: String,
        tool: String?
    ) -> Bool {
        let family = family(of: plugin)
        let familyGrants = grants.filter { $0.botId == botId && Self.family(of: $0.plugin) == family }
        if familyGrants.isEmpty { return true }
        let scoped = familyGrants.filter { $0.plugin == plugin }
        if scoped.isEmpty { return false }
        if scoped.contains(where: { $0.tool == nil }) { return true }
        guard let tool, !tool.isEmpty else { return false }
        return scoped.contains { $0.tool == tool }
    }

    public static func family(of plugin: String) -> String {
        if plugin.hasPrefix("mcp:") { return "mcp" }
        if plugin.hasPrefix("component-data:") { return "component-data" }
        if plugin.hasPrefix("component:") { return "component" }
        return "plugin"
    }

    public static func isGranted(
        grants: [PluginGrant],
        botId: String,
        plugin: String,
        tool: String? = nil
    ) -> Bool {
        allows(grants: grants, botId: botId, plugin: plugin, tool: tool)
    }
}
