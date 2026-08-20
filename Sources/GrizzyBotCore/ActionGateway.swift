import Foundation

public enum ActionGateway {
    public static let computerTools: Set<String> = [
        "computer_screenshot", "computer_open", "computer_click",
        "computer_type", "computer_key", "computer_scroll",
    ]

    public static func isComputerTool(_ name: String) -> Bool {
        computerTools.contains(name)
    }

    public static func intent(
        tool: String,
        key: String? = nil,
        mcpEffect: McpEffect? = nil
    ) -> PolicyIntent? {
        switch tool {
        case "computer_screenshot":
            return .read
        case "computer_open":
            return .navigate
        case "computer_click":
            return .activate
        case "computer_type":
            return .type
        case "computer_key":
            let lowered = (key ?? "").lowercased()
            if lowered == "enter" || lowered == "return" || lowered == "space" || lowered == " "
                || lowered.hasSuffix("+enter") {
                return .activate
            }
            return .type
        case "computer_scroll":
            return .read
        case "read_file", "read_file.host":
            return .readFile
        case "write_file", "edit_file", "delete_file", "move_file", "destination_write":
            return .writeFile
        case "list_files", "list_files.host":
            return .listFiles
        case "web_search", "web_fetch", "search_memory", "search_knowledge",
             "mcp_list_tools", "read_skill", "plugin_call_read":
            return .read
        case "shell", "shell.exec", "remember", "forget", "import_skills",
             "plugin_call", "spawn_bot", "delete_bot":
            return .writeFile
        case "mcp_call":
            return mcpEffect == .read ? .readTool : .writeTool
        case "present_component":
            return .read
        case "report_decline", "request_takeover":
            return .read
        default:
            if tool.hasPrefix("computer_") { return .activate }
            return nil
        }
    }

    public static func context(
        tool: String,
        argumentsJSON: String,
        botId: String,
        actorId: String,
        pageURL: String = "",
        pageHost: String = "",
        element: PolicyElement? = nil,
        mcpServer: McpServer? = nil,
        advertisedMcpTool: Bool = false
    ) -> PolicyContext {
        let args = JSONValue.object(JSONValue.parseObject(argumentsJSON))
        func s(_ keys: String...) -> String {
            for key in keys {
                if let value = args.stringValue(key) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return ""
        }

        var url = pageURL
        var host = pageHost
        if tool == "computer_open" {
            url = s("url")
            host = URL(string: url)?.host ?? host
        }

        var file: PolicyFile?
        let path = s("path", "filepath", "file")
        if !path.isEmpty, ["read_file", "write_file", "edit_file", "delete_file", "move_file",
                           "list_files", "read_file.host", "list_files.host"].contains(tool) {
            file = PolicyFile(path: path)
        }

        var mcp: PolicyMcp?
        var mcpEffect: McpEffect?
        if tool == "mcp_call" || tool == "mcp_list_tools" {
            let mcpTool = tool == "mcp_list_tools" ? "list_tools" : s("tool", "name")
            let effect: McpEffect
            if tool == "mcp_list_tools" {
                effect = .read
            } else {
                effect = McpCatalog.classify(
                    server: mcpServer,
                    toolName: mcpTool,
                    advertised: advertisedMcpTool
                )
            }
            mcpEffect = effect
            mcp = PolicyMcp(
                server: mcpServer?.name ?? s("server"),
                tool: mcpTool,
                effect: effect
            )
        }

        let key = tool == "computer_key" ? s("key") : nil
        return PolicyContext(
            toolName: tool,
            botId: botId,
            actorId: actorId,
            pageURL: url,
            pageHost: host,
            intent: intent(tool: tool, key: key, mcpEffect: mcpEffect),
            key: key,
            element: element,
            file: file,
            mcp: mcp
        )
    }

    public static func decide(policy: ActionPolicy?, context: PolicyContext) -> PolicyDecision {
        ActionPolicyEngine.evaluate(policy, context: context)
    }

    public static func humanDrivingRefusal(tool: String) -> (output: String, reason: String) {
        let reason = "A person is driving this computer. Bot actions are refused until they release control."
        return ("Refused \(tool): \(reason)", reason)
    }

    public static func auditType(for tool: String, decision: PolicyDecision, failed: Bool) -> AuditEventType {
        if failed { return .computerActionFailed }
        if isComputerTool(tool) {
            return decision.forward ? .computerActionAllowed : .computerActionRefused
        }
        if tool == "mcp_call" || tool == "mcp_list_tools" {
            return decision.forward ? .mcpCallSucceeded : .mcpCallRejected
        }
        if tool == "present_component" {
            return decision.forward ? .componentInvoked : .componentRefused
        }
        return decision.forward ? .computerActionAllowed : .computerActionRefused
    }
}
