import Foundation

/// AionUi-style assistant presets: name, instructions, default skills/tools.
public struct BotTemplate: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var title: String
    public var blurb: String
    public var instructions: String
    public var skillIds: [String]
    public var toolIds: [String]
    /// MCP tools to switch on, keyed by lowercased server name. Resolved to the
    /// workspace's server ids when a bot is created; servers that are not
    /// configured are skipped.
    public var mcpTools: [String: [String]]

    public init(
        id: String,
        name: String,
        title: String,
        blurb: String,
        instructions: String,
        skillIds: [String],
        toolIds: [String] = AgentToolCatalog.builtinIds,
        mcpTools: [String: [String]] = BotTemplates.hindsightOnly
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.blurb = blurb
        self.instructions = instructions
        self.skillIds = skillIds
        self.toolIds = toolIds
        self.mcpTools = mcpTools
    }
}

public enum BotTemplates {
    public static let all: [BotTemplate] = [standard, orchestrator, coworker, researcher, writer, coder, desktopOperator]

    // MARK: Tool sets
    //
    // Every template starts from `baseTools` and adds only what the role needs;
    // anything not listed is off, and can be switched on in the bot's settings.

    /// Files, memory, skills, checklists and artifacts. No shell, no computer, no web.
    public static let baseTools: [String] = [
        "read_skill", "todo", "complete", "clarify", "report_decline",
        "remember", "search_memory", "forget", "search_knowledge",
        "capabilities_discover", "capabilities_load", "present_component",
        "list_files", "read_file", "write_file", "edit_file",
        "artifact_create", "artifact_update", "artifact_rewrite", "artifact_list", "artifact_read",
    ]

    public static let computerTools: [String] = [
        "request_takeover", "computer_screenshot", "computer_open", "computer_click",
        "computer_type", "computer_key", "computer_scroll",
    ]

    /// Hindsight is the long-term memory every bot shares: store, search, synthesize.
    /// The admin surface (banks, documents, operations, deletes) stays off.
    public static let hindsightTools = ["retain", "recall", "reflect"]
    public static let hindsightOnly: [String: [String]] = ["hindsight": hindsightTools]

    static let toolportTools = ["toolport_status", "toolport_search_tools", "toolport_call_tool", "toolport_fetch_result"]
    static let desktopCommanderFiles = [
        "read_file", "read_multiple_files", "write_file", "edit_block", "create_directory",
        "list_directory", "move_file", "get_file_info",
        "start_search", "get_more_search_results", "stop_search",
    ]
    static let desktopCommanderProcesses = [
        "start_process", "read_process_output", "interact_with_process",
        "force_terminate", "list_processes", "kill_process",
    ]

    public static let standard = BotTemplate(
        id: "standard",
        name: "Standard",
        title: "",
        blurb: "The starting point for any new bot: files, web search, memory, no shell or computer. Adjust from here.",
        instructions: """
        You are a helpful assistant on this Mac. Use skills when they fit. Prefer tools over guessing.
        Check Hindsight (recall) for relevant context before you start, and retain durable facts and decisions when you finish.
        """,
        skillIds: ["memory", "workspace-memory", "file-organizer"],
        toolIds: baseTools + ["web_search", "move_file"]
    )

    public static let orchestrator = BotTemplate(
        id: "orchestrator",
        name: "Orchestrator",
        title: "Chief of staff",
        blurb: "Plans, delegates to other bots, and follows through. No shell or computer of its own.",
        instructions: """
        You lead. Break the goal into steps, hand each to the right bot (create one if none fits), and verify the result before you report.
        Keep answers short. Recall from Hindsight before planning; retain decisions and outcomes.
        """,
        skillIds: [
            "orchestration", "planning-and-task-breakdown", "memory", "workspace-memory",
            "research", "office-docs", "file-organizer", "find-skills",
        ],
        toolIds: baseTools + [
            "web_search", "spawn_bot", "message_bot", "delete_bot", "run_subagent",
            "destination_write", "plugin_call",
        ],
        mcpTools: [
            "hindsight": hindsightTools + ["list_mental_models", "get_mental_model"],
            "toolport": toolportTools,
        ]
    )

    public static let coworker = BotTemplate(
        id: "coworker",
        name: "Coworker",
        title: "General coworker",
        blurb: "Files, search, memory, and the computer — pick this if you're not sure.",
        instructions: """
        You are a general coworker on this Mac. Use skills when they fit: research, office-docs, coding, browser, memory.
        Prefer tools over guessing. Write real files when the user wants a deliverable.
        """,
        skillIds: ["research", "office-docs", "browser", "memory", "workspace-memory", "file-organizer"],
        toolIds: baseTools + computerTools + [
            "web_search", "shell", "move_file", "run_subagent", "message_bot",
            "destination_write", "plugin_call", "shortcuts_list", "shortcuts_run",
        ],
        mcpTools: [
            "hindsight": hindsightTools,
            "toolport": toolportTools,
            "desktop-commander": desktopCommanderFiles,
        ]
    )

    public static let researcher = BotTemplate(
        id: "researcher",
        name: "Researcher",
        title: "Research & briefs",
        blurb: "Web search, cited notes, and saved briefs.",
        instructions: """
        You research. Always load the research skill first.
        Search, fetch sources, cite URLs, and write briefs under notes/ when asked for a file.
        """,
        skillIds: ["research", "memory", "office-docs", "file-organizer"],
        toolIds: baseTools + ["web_search"],
        mcpTools: [
            "hindsight": hindsightTools,
            "toolport": toolportTools,
        ]
    )

    public static let writer = BotTemplate(
        id: "writer",
        name: "Writer",
        title: "Docs & drafts",
        blurb: "Reports, outlines, CSV tables, HTML slides.",
        instructions: """
        You produce documents. Load office-docs before writing a file.
        Default to markdown reports, CSV tables, and HTML slide decks in notes/.
        Match the user's tone from memory when it exists.
        """,
        skillIds: ["office-docs", "memory", "research"],
        toolIds: baseTools + ["web_search"]
    )

    public static let coder = BotTemplate(
        id: "coder",
        name: "Coder",
        title: "Code in the bot home",
        blurb: "Read, edit, and run code inside this bot's files.",
        instructions: """
        You write and run code in your bot home. Load the coding skill first.
        Read before you edit. Run commands with shell. Summarize the diff.
        """,
        skillIds: [
            "coding", "memory", "workspace-memory", "swiftui-pro", "code-review-and-quality",
            "code-simplification", "debugging-and-error-recovery", "test-driven-development",
            "git-workflow-and-versioning", "incremental-implementation",
            "planning-and-task-breakdown", "security-and-hardening", "understand",
        ],
        toolIds: baseTools + ["web_search", "shell", "move_file", "delete_file", "run_subagent"],
        mcpTools: [
            "hindsight": hindsightTools,
            "desktop-commander": desktopCommanderFiles + desktopCommanderProcesses,
        ]
    )

    public static let desktopOperator = BotTemplate(
        id: "operator",
        name: "Operator",
        title: "Drive this Mac",
        blurb: "Open sites, screenshot, click, type, hand over for login.",
        instructions: """
        You operate the live computer. Load the browser skill first.
        Screenshot before every click. Take over when a human must sign in.
        """,
        skillIds: ["browser", "memory"],
        toolIds: [
            "read_skill", "todo", "complete", "clarify", "report_decline",
            "remember", "search_memory", "forget", "capabilities_discover", "capabilities_load",
            "present_component", "list_files", "read_file", "write_file",
            "web_search", "shortcuts_list", "shortcuts_run",
        ] + computerTools
    )
}
