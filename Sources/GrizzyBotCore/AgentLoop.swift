import Foundation

public enum AgentPause: Sendable, Equatable {
    case takeover
    case waitingInput
    case approval(tool: String, detail: String, arguments: String)
}

public struct AgentHistoryTurn: Sendable, Equatable {
    public var role: MessageRole
    public var text: String

    public init(role: MessageRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// One sibling bot as the roster shows it in the system prompt.
public struct BotRosterEntry: Sendable, Equatable {
    public var name: String
    public var title: String
    /// True when the bot reading the prompt created this one.
    public var isChild: Bool
    /// True when this bot is the workspace chief of staff.
    public var isChiefOfStaff: Bool

    public init(name: String, title: String = "", isChild: Bool = false, isChiefOfStaff: Bool = false) {
        self.name = name
        self.title = title
        self.isChild = isChild
        self.isChiefOfStaff = isChiefOfStaff
    }
}

public struct AgentLoopRequest: Sendable {
    public var endpoint: ModelEndpoint
    public var botName: String
    public var botTitle: String
    public var instructions: String
    public var memory: String
    public var sharedMemory: String
    public var skillCatalog: String
    public var homePath: String
    public var history: [AgentHistoryTurn]
    public var priorMessages: [ChatMessage]
    public var prompt: String
    /// Optional JPEG for the current user turn (dropped screenshot / image).
    public var promptImageJPEGBase64: String?
    public var tools: [ChatTool]
    public var maxSteps: Int
    public var depth: Int
    public var charBudget: Int
    /// Honest computer status for the system prompt (browser cookies, this Mac, or none).
    public var computerNote: String
    /// Optional working-folder note for relative file paths.
    public var workingFolderNote: String
    /// Silence limit for the model stream. 0 disables.
    public var stallMs: Int
    /// The other bots in this workspace, so a bot never has to go hunting on disk for them.
    public var roster: [BotRosterEntry]
    /// True when this bot is the chief of staff and owns coordination across the roster.
    public var isChiefOfStaff: Bool

    public init(
        endpoint: ModelEndpoint,
        botName: String,
        botTitle: String = "",
        instructions: String = "",
        memory: String = "",
        sharedMemory: String = "",
        skillCatalog: String = "",
        homePath: String = "",
        history: [AgentHistoryTurn] = [],
        priorMessages: [ChatMessage] = [],
        prompt: String,
        promptImageJPEGBase64: String? = nil,
        tools: [ChatTool],
        maxSteps: Int = 48,
        depth: Int = 0,
        charBudget: Int = 100_000,
        computerNote: String = "",
        workingFolderNote: String = "",
        stallMs: Int = 60_000,
        roster: [BotRosterEntry] = [],
        isChiefOfStaff: Bool = false
    ) {
        self.endpoint = endpoint
        self.botName = botName
        self.botTitle = botTitle
        self.instructions = instructions
        self.memory = memory
        self.sharedMemory = sharedMemory
        self.skillCatalog = skillCatalog
        self.homePath = homePath
        self.history = history
        self.priorMessages = priorMessages
        self.prompt = prompt
        self.promptImageJPEGBase64 = promptImageJPEGBase64
        self.tools = tools
        self.maxSteps = maxSteps
        self.depth = depth
        self.charBudget = charBudget
        self.computerNote = computerNote
        self.workingFolderNote = workingFolderNote
        self.stallMs = stallMs
        self.roster = roster
        self.isChiefOfStaff = isChiefOfStaff
    }
}

public struct AgentToolCallResult: Sendable {
    public var output: String
    public var blocks: [MessageBlock]
    public var pause: AgentPause?
    public var imageJPEGBase64: String?
    /// First-class MCP catalog tools discovered this call (Toolport search / MacUse definitions).
    public var promotedMcpTools: [McpPromotedTool]
    /// Skill bodies loaded mid-turn via capabilities_load.
    public var loadedSkillBodies: [(id: String, body: String)]
    /// When true, end the agent loop after this tool (complete).
    public var endTurn: Bool

    public init(
        output: String,
        blocks: [MessageBlock] = [],
        pause: AgentPause? = nil,
        imageJPEGBase64: String? = nil,
        promotedMcpTools: [McpPromotedTool] = [],
        loadedSkillBodies: [(id: String, body: String)] = [],
        endTurn: Bool = false
    ) {
        self.output = output
        self.blocks = blocks
        self.pause = pause
        self.imageJPEGBase64 = imageJPEGBase64
        self.promotedMcpTools = promotedMcpTools
        self.loadedSkillBodies = loadedSkillBodies
        self.endTurn = endTurn
    }
}

public struct AgentLoopResult: Sendable {
    public var text: String
    public var blocks: [MessageBlock]
    public var pause: AgentPause?
    /// Billed input of the first model call this turn (prompt + system + history).
    public var promptTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var steps: Int
    public var messages: [ChatMessage]
    public var compacted: Bool
    public var failed: Bool
    public var failureReason: String?

    public init(
        text: String,
        blocks: [MessageBlock] = [],
        pause: AgentPause? = nil,
        promptTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        steps: Int = 0,
        messages: [ChatMessage] = [],
        compacted: Bool = false,
        failed: Bool = false,
        failureReason: String? = nil
    ) {
        self.text = text
        self.blocks = blocks
        self.pause = pause
        self.promptTokens = promptTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.steps = steps
        self.messages = messages
        self.compacted = compacted
        self.failed = failed
        self.failureReason = failureReason
    }
}

/// Deterministic end-of-turn check: never trust chat text over tool cards.
public enum AgentCompletionGate {
    public static func claimsVaultWrite(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("vault note written") { return true }
        if t.contains("successfully uploaded") { return true }
        let mentionedInbox = t.contains("inbox/") && t.contains(".md")
        let wrote = t.contains("wrote") || t.contains("saved") || t.contains("written") || t.contains("uploaded")
        if mentionedInbox && wrote { return true }
        if t.contains("obsidian") && wrote { return true }
        return false
    }

    public static func confirmedVaultWrite(messages: [ChatMessage], blocks: [MessageBlock]) -> Bool {
        for message in messages where message.role == "tool" {
            let content = (message.content ?? "").lowercased()
            if content.contains("tool error") { continue }
            if content.contains("successfully uploaded") { return true }
            if content.contains("obsidian_put_file") || content.contains("put_file") {
                if content.contains("uploaded") || content.contains("ok") { return true }
            }
        }
        for block in blocks {
            guard case .card(let lines) = block else { continue }
            var tool = ""
            var status = ""
            for line in lines {
                if line.k == "tool" { tool = line.v.lowercased() }
                if line.k == "status" { status = line.v.lowercased() }
            }
            let writeTool = tool.contains("put_file") || tool.contains("obsidian")
            if writeTool && status == "ok" { return true }
        }
        return false
    }

    public static func unconfirmedVaultWrite(
        text: String,
        messages: [ChatMessage],
        blocks: [MessageBlock]
    ) -> Bool {
        claimsVaultWrite(text) && !confirmedVaultWrite(messages: messages, blocks: blocks)
    }
}

public enum ContextCompactor {
    /// Written as statements rather than one chained `reduce`: the single
    /// expression mixed optionals with a nested reduce and blew the type
    /// checker's budget on the CI toolchain, failing the whole build.
    public static func encodedSize(_ messages: [ChatMessage]) -> Int {
        var total = 0
        for message in messages {
            total += message.role.count
            total += message.content?.count ?? 0
            for call in message.toolCalls {
                total += call.name.count
                total += call.arguments.count
            }
            total += message.imageJPEGBase64?.count ?? 0
        }
        return total
    }

    /// Keep system + newest turns; shrink tool payloads and stuffed user pastes.
    public static func compact(_ messages: [ChatMessage], budget: Int) -> (messages: [ChatMessage], compacted: Bool) {
        let original = encodedSize(messages)
        guard original > budget else { return (messages, false) }
        var copy = messages
        if copy.count > 4 {
            shrinkTools(&copy, keepLast: 6)
            if encodedSize(copy) > budget {
                shrinkTools(&copy, keepLast: 0)
            }
            if encodedSize(copy) > budget, copy.count > 8 {
                let head = copy.prefix(1)
                let tail = copy.suffix(6)
                let dropped = copy.count - 7
                let note = ChatMessage(
                    role: "user",
                    content: "[Earlier in this job, \(dropped) messages were compacted to stay within context.]"
                )
                copy = Array(head) + [note] + Array(tail)
            }
        }
        if encodedSize(copy) > budget {
            shrinkOversizedText(&copy)
        }
        return (copy, encodedSize(copy) < original)
    }

    private static func shrinkOversizedText(_ copy: inout [ChatMessage]) {
        for i in copy.indices {
            guard let content = copy[i].content, content.count > 2_500 else { continue }
            if copy[i].role == "user" || copy[i].role == "system" {
                copy[i].content = summarizePayload(content, head: 1_200, tail: 600)
            }
        }
    }

    private static func shrinkTools(_ copy: inout [ChatMessage], keepLast: Int) {
        let start = max(1, copy.count - keepLast)
        for i in 1..<start {
            if copy[i].role == "tool", let content = copy[i].content, content.count > 900 {
                copy[i].content = summarizePayload(content)
                copy[i].imageJPEGBase64 = nil
            }
            if copy[i].role == "assistant", copy[i].toolCalls.count > 0 {
                copy[i].toolCalls = copy[i].toolCalls.map { call in
                    var next = call
                    if next.arguments.count > 800 {
                        next.arguments = compactToolArguments(next.arguments)
                    }
                    return next
                }
            }
        }
    }

    /// Keep head + tail so the model still sees how a tool result started and ended.
    public static func summarizePayload(_ content: String, head: Int = 600, tail: Int = 300) -> String {
        if content.count <= head + tail + 80 { return content }
        let omitted = content.count - head - tail
        return String(content.prefix(head))
            + "\n…[summarized \(omitted) chars]…\n"
            + String(content.suffix(tail))
    }

    public static func isValidJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// LM Studio (and some other local servers) 500 when `tool_calls[].function.arguments` is not valid JSON.
    public static func ensureValidJSONArguments(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        if isValidJSON(trimmed) { return trimmed }
        return wrappedToolArguments(trimmed)
    }

    /// Shrink oversized tool-call JSON while remaining parseable. Never splice a summary into raw JSON.
    public static func compactToolArguments(_ arguments: String, limit: Int = 800) -> String {
        if arguments.count <= limit, isValidJSON(arguments) { return arguments }
        if var object = jsonObject(arguments) {
            shrinkJSONStringValues(&object)
            if let encoded = encodeJSON(object) {
                if encoded.count <= max(limit, 1_200) || isValidJSON(encoded) {
                    return encoded
                }
            }
        }
        return wrappedToolArguments(arguments)
    }

    static func wrappedToolArguments(_ arguments: String, previewLimit: Int = 400) -> String {
        let preview = String(arguments.prefix(previewLimit))
        let payload: [String: Any] = [
            "_compacted": true,
            "omitted": max(0, arguments.count - preview.count),
            "preview": preview,
        ]
        return encodeJSON(payload) ?? #"{"_compacted":true}"#
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    private static func shrinkJSONStringValues(_ object: inout [String: Any]) {
        for (key, raw) in object {
            if let string = raw as? String, string.count > 400 {
                object[key] = summarizePayload(string, head: 220, tail: 80)
            } else if var nested = raw as? [String: Any] {
                shrinkJSONStringValues(&nested)
                object[key] = nested
            }
        }
    }
}

public enum StreamText {
    /// Drop model chain-of-thought tags so they never show in chat.
    public static func visible(_ raw: String) -> String {
        var text = raw
        text = text.replacing(/<think>[\s\S]*?<\/think>/, with: "")
        text = text.replacing(/<think>[\s\S]*/, with: "")
        text = text.replacing(/<\/think>/, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OpenAI/Anthropic tool-calling loop. The store supplies tool execution.
public enum AgentLoop {
    public enum PromptSection {
        public static func identity(botName: String) -> String {
            "You are \(botName), a GrizzyBot agent running on this Mac."
        }

        public static func agency() -> String {
            "You are a fully capable agent: think, use tools, and keep going until the user's request is done or you must wait for them."
        }

        public static func honesty() -> String {
            "Be concise. Prefer tools over guessing. Never claim you wrote a file, saved a canvas, ran a command, searched, signed in, or called a plugin unless a tool result says so."
        }

        public static func sandbox() -> String {
            """
            Shell runs inside a macOS seatbelt sandbox rooted at your home. If a working folder is set for this run, shell may also write inside that folder (mv, rm, mkdir). Destructive shell and plugin writes pause for user approval unless always-allowed.
            Shell default timeout is \(Int(BotHomeStore.ShellTimeout.default))s. For multi-step research (curl loops, sleeps), pass timeout_seconds up to \(Int(BotHomeStore.ShellTimeout.max)) or split into shorter commands.
            Keep going across many tool rounds. If context is compacted, trust the remaining transcript and continue the job.
            """
        }

        public static func memory() -> String {
            "Memory in this prompt is pinned standing rules plus the newest facts. Use search_memory for older facts. Use forget when a fact is wrong or outdated."
        }

        public static func planFile() -> String {
            "For jobs that span turns, keep PLAN.md in your home with read_file/write_file and update it as you go."
        }

        public static func builtinAvailability(tools: [ChatTool]) -> String? {
            DisabledBuiltinFallback.promptNote(
                available: Set(tools.map(\.function.name)),
                context: McpFallbackContext.from(tools: tools)
            )
        }

        public static func filesAndMcp(tools: [ChatTool] = [], hasWorkingFolder: Bool = false) -> String {
            let mcpCall = tools.first { $0.function.name == "mcp_call" }
            let desc = mcpCall?.function.description ?? ""
            let hasGateway = desc.lowercased().contains("toolport")
                || desc.lowercased().contains("conduit-gateway")
            let servers = McpToolRouting.parseServerList(from: desc)
            let mcpLine: String
            if !tools.isEmpty, mcpCall == nil {
                mcpLine = "No MCP servers are enabled. Do not call mcp_call, toolport_*, or invent a Toolport gateway."
            } else if hasGateway {
                mcpLine = """
                MCP: Prefer first-class catalog tools already in your list (e.g. gmail__messages_list, github__search_repositories, macuse__mail_search_messages) — call them directly with their arguments. Otherwise mcp_list_tools once then mcp_call. Toolport is a lazy gateway — list returns search/call meta-tools. Pass a catalog name as mcp_call's tool, or as arguments.name on toolport_call_tool (not id, never empty). Prefer filepath+content; path maps to filepath. Do not invent catalog names. Do not curl those APIs when an MCP tool exists.
                When Toolport already returned article titles or a dataset, summarize and write. Do not call toolport_fetch_result (cursors expire). Do not toolport_run_script to inspect JSON.
                If a builtin is missing or a tool result says it is disabled, do not ask the user to enable it. mcp_call Toolport for that job: search once (fast-filesystem for files, web search for news), then call the catalog tool with the same arguments. Do not paste the deliverable in chat until Toolport succeeds.
                """
            } else {
                let listed = servers.isEmpty ? "the names on mcp_call" : servers.joined(separator: ", ")
                mcpLine = """
                MCP: Prefer first-class tools already in your list (names like server__tool) — call them directly with their arguments. Otherwise mcp_list_tools once with server=<one of: \(listed)>, then mcp_call with that same server. Never omit server when more than one MCP is enabled. Do not call Toolport or toolport_* unless Toolport is in that server list. Ignore standing memory that says all tools go through Toolport if it is not listed. Prefer filepath+content; path maps to filepath. Do not invent catalog names. Do not curl those APIs when an MCP tool exists.
                If a builtin is missing or a tool result says it is disabled, do not ask the user to enable it. Use the matching first-class MCP tool or mcp_call the server that does that job (fast-filesystem for files, ddg-search / firecrawl for web). Do not paste the deliverable in chat until that MCP call succeeds.
                """
            }
            let fileLines: String
            if hasWorkingFolder {
                fileLines = """
                Relative read_file, write_file, edit_file, move_file, delete_file, and list_files use the working folder named below (empty list_files lists it). That folder is the file root for this run on every bot — not the bot home or a knowledge vault. Absolute/~ paths outside that folder pause for approval. write_file there writes that folder on disk. Home path remains the sandbox for MEMORY.md, PLAN.md, and shell HOME. Shell ~ is never the working folder, but shell may write inside the working folder (mv/rm). MCP does not inherit the working folder; pass absolute paths. Prefer move_file over shell scripts when organizing files.
                """
            } else {
                fileLines = """
                read_file and list_files read the bot home. Absolute/~ paths on this Mac pause for approval (for example ~/.agents/skills). Prefer them over shell cat.
                write_file only writes the bot sandbox (Home path), not the user's Obsidian vault.
                """
            }
            return """
            \(fileLines)
            \(mcpLine)
            If a tool result reports validation, no route, or connection refused, follow the recovery hint in that result — fix args, re-search once, or fall back to write_file/web — do not repeat the identical failing call.
            Canvas is shared on this Mac: canvas_list, canvas_open, canvas_save, canvas_delete, canvas_place_image. write_file cannot write a canvas. After computer_screenshot, call canvas_open (it places the last screenshot) or canvas_place_image.
            Artifacts are shared on this Mac: artifact_create, artifact_update, artifact_rewrite, artifact_list, artifact_read, artifact_delete. Create one for substantial standalone content the user will keep, re-read, or run — a document, a program, a diagram, a small app — and answer in the reply for anything conversational or short. Put the whole thing in the artifact rather than repeating it in the reply. To change one you already made, call artifact_update with a unique old_str; re-read it first with artifact_read if you did not write it this turn. Each artifact is also mirrored into the working folder as a file, so do not also write_file the same content.
            If the user asked you to write a prompt or instructions for an agent, write that prompt. Do not run the job unless they asked you to execute it.
            Shell ~ is the bot home, not the Mac home.
            Never claim an Obsidian write unless the tool result names obsidian_put_file (or that server's write tool) and status is ok.
            """
        }

        public static func governance() -> String {
            """
            Prefer present_component (form, gallery, activity, refusals) over dumping tables as prose. search_knowledge only sees sources you are granted. If a tool result says the workspace policy refused the action, do not retry the same call — change the approach or tell the user.
            While a person is driving the computer, computer_* tools are refused. Wait.
            """
        }

        /// The workspace roster. Without it a bot has no idea its siblings exist
        /// and goes spelunking through Application Support to find them.
        public static func roster(
            _ entries: [BotRosterEntry],
            isChiefOfStaff: Bool,
            canMessage: Bool
        ) -> String? {
            guard !entries.isEmpty else {
                return isChiefOfStaff
                    ? "You are the chief of staff for this workspace. No other bots exist yet — spawn_bot when a job deserves its own standing bot."
                    : nil
            }
            let lines = entries.map { entry -> String in
                var tags: [String] = []
                if entry.isChiefOfStaff { tags.append("chief of staff") }
                if entry.isChild { tags.append("you created it") }
                let role = entry.title.isEmpty ? "" : " — \(entry.title)"
                let tag = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
                return "- \(entry.name)\(role)\(tag)"
            }
            var text = """
            Other bots in this workspace:
            \(lines.joined(separator: "\n"))
            This list is complete and authoritative. Do not shell around Application Support or the bot homes looking for bots — it is already here.
            """
            if canMessage {
                text += "\nUse message_bot to hand a job to one of them instead of duplicating its work or spawning a near-copy. It works in its own thread and by default you wait for its answer, so fold that answer into your reply rather than telling the user to go read another thread. Pass wait:false only for long background jobs you are not reporting on this turn. Reach for spawn_bot only when no listed bot fits."
            }
            if isChiefOfStaff {
                text += "\nYou are the chief of staff: you own coordination across these bots. Route work to the right one, keep track of what you delegated, and say who is doing what."
            }
            return text
        }

        public static func computer(_ note: String) -> String {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Computer: no live session is attached. Do not claim you can see or click a desktop until a screenshot tool succeeds."
            }
            return "Computer: \(trimmed)"
        }
    }

    public static func systemPrompt(for request: AgentLoopRequest, now: Date = .now) -> String {
        var lines: [String] = [
            PromptSection.identity(botName: request.botName),
            utcDateLine(now: now),
            PromptSection.agency(),
            PromptSection.honesty(),
            PromptSection.sandbox(),
            PromptSection.memory(),
            PromptSection.planFile(),
            PromptSection.filesAndMcp(
                tools: request.tools,
                hasWorkingFolder: !request.workingFolderNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ),
            PromptSection.governance(),
            AppConfig.keysHelp,
            PromptSection.computer(request.computerNote),
        ]
        if let builtinNote = PromptSection.builtinAvailability(tools: request.tools) {
            lines.append(builtinNote)
        }
        if !request.homePath.isEmpty {
            lines.append("Home path: \(request.homePath)")
        }
        let working = request.workingFolderNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !working.isEmpty {
            lines.append(working)
        }
        lines.append(
            "For unfamiliar skills or MCP catalog tools, call capabilities_discover then capabilities_load before inventing tool names. For multi-step work, use todo / complete / clarify."
        )
        if !request.botTitle.isEmpty {
            lines.append("Role: \(request.botTitle)")
        }
        let instructions = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            lines.append("Instructions from the user:\n\(instructions)")
        }
        if let roster = PromptSection.roster(
            request.roster,
            isChiefOfStaff: request.isChiefOfStaff,
            canMessage: request.tools.contains(where: { $0.function.name == "message_bot" })
        ) {
            lines.append(roster)
        }
        let memory = request.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty {
            lines.append("Durable memory:\n\(memory)")
        }
        let shared = request.sharedMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shared.isEmpty {
            lines.append("Shared workspace memory (every bot on this Mac):\n\(shared)")
        }
        let skills = request.skillCatalog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skills.isEmpty {
            lines.append(skills)
        }
        if request.depth > 0 {
            lines.append("You are a short-lived helper for one task. Do not spawn bots.")
        }
        return lines.joined(separator: "\n\n")
    }

    public static func utcDateLine(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let yesterday = formatter.string(from: now.addingTimeInterval(-86_400))
        return "Today is \(today) (UTC). Yesterday UTC is \(yesterday). Use these dates in search filters; do not call shell for the date."
    }

    public static let parallelSafeTools: Set<String> = [
        "web_search", "web_fetch", "read_file", "list_files", "search_memory",
        "computer_screenshot", "mcp_list_tools", "read_skill", "search_knowledge",
        "canvas_list", "artifact_list", "artifact_read",
    ]

    public static func run(
        client: any ChatCompleting,
        request: AgentLoopRequest,
        onDelta: (@Sendable (String) -> Void)? = nil,
        onStep: (@Sendable (Int, Int) -> Void)? = nil,
        onTool: (@Sendable (String, String, AgentToolCallResult) -> Void)? = nil,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async throws -> AgentLoopResult {
        var messages: [ChatMessage] = [.system(systemPrompt(for: request))]
        if !request.priorMessages.isEmpty {
            messages.append(contentsOf: request.priorMessages.filter { $0.role != "system" })
        } else {
            for turn in request.history {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                switch turn.role {
                case .user:
                    messages.append(.user(text))
                case .bot:
                    messages.append(.assistant(text))
                case .system:
                    messages.append(.system(text))
                }
            }
        }
        messages.append(
            ChatMessage(
                role: "user",
                content: request.prompt,
                imageJPEGBase64: request.promptImageJPEGBase64
            )
        )

        var blocks: [MessageBlock] = []
        var inputTokens = 0
        var outputTokens = 0
        var promptTokens = 0
        var lastText = ""
        var pause: AgentPause?
        var compacted = false
        let maxSteps = max(1, request.maxSteps)
        var tools = request.tools
        var webFails = 0
        var mcpDeadEnds = 0
        var warnedMcpStall = false
        let hasMcpTools = tools.contains { $0.function.name == "mcp_call" }

        func persistable() -> [ChatMessage] {
            Array(messages.drop(while: { $0.role == "system" }).prefix(200))
        }

        func loopResult(
            text: String,
            steps: Int,
            failed: Bool = false,
            failureReason: String? = nil
        ) -> AgentLoopResult {
            AgentLoopResult(
                text: text,
                blocks: blocks,
                pause: pause,
                promptTokens: promptTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                steps: steps,
                messages: persistable(),
                compacted: compacted,
                failed: failed,
                failureReason: failureReason
            )
        }

        func modelRequest(
            onDelta: (@Sendable (String) -> Void)?,
            charBudget: Int
        ) async throws -> ChatCompletionResponse {
            var lastError: Error?
            var retryBudget = charBudget
            for attempt in 0..<ModelRequestRetry.maxAttempts {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: ModelRequestRetry.backoffNanoseconds(attempt: attempt - 1))
                    if let lastError, ModelRequestRetry.shouldCompactOnRetry(lastError) {
                        retryBudget = max(8_000, retryBudget * 3 / 4)
                        let tighter = ContextCompactor.compact(messages, budget: retryBudget)
                        messages = tighter.messages
                        if tighter.compacted { compacted = true }
                    }
                }
                let chatRequest = ChatCompletionRequest(
                    endpoint: request.endpoint,
                    messages: messages,
                    tools: tools,
                    stallMs: request.stallMs
                )
                do {
                    if let onDelta {
                        return try await client.stream(chatRequest, onDelta: onDelta)
                    }
                    return try await client.complete(chatRequest)
                } catch {
                    lastError = error
                    if error is CancellationError { throw error }
                    if attempt + 1 < ModelRequestRetry.maxAttempts, ModelRequestRetry.isRetryable(error) {
                        continue
                    }
                    throw error
                }
            }
            throw lastError ?? LLMError.emptyResponse
        }

        for step in 1...maxSteps {
            if Task.isCancelled { throw CancellationError() }
            onStep?(step, maxSteps)
            let packed = ContextCompactor.compact(messages, budget: request.charBudget)
            messages = packed.messages
            if packed.compacted { compacted = true }

            let response: ChatCompletionResponse
            do {
                response = try await modelRequest(onDelta: onDelta, charBudget: request.charBudget)
            } catch {
                if error is CancellationError { throw error }
                if let llm = error as? LLMError, case .stalled(let silent, let chunks) = llm {
                    return loopResult(
                        text: "The model stopped responding. Nothing arrived from it for \(StallClock.words(ms: silent)).",
                        steps: step,
                        failed: true,
                        failureReason: "AGENT_STREAM_STALLED chunks=\(chunks)"
                    )
                }
                if !blocks.isEmpty {
                    let detail = error.localizedDescription
                    return loopResult(
                        text: "The model stopped responding (\(detail)). Tool results above may still be useful — ask me to continue.",
                        steps: step,
                        failed: true,
                        failureReason: "model stopped responding"
                    )
                }
                throw error
            }
            inputTokens += response.inputTokens
            outputTokens += response.outputTokens
            if step == 1 {
                promptTokens = response.inputTokens
            }
            lastText = StreamText.visible(response.text)

            if !response.hasToolCalls {
                if AgentCompletionGate.unconfirmedVaultWrite(
                    text: lastText,
                    messages: messages,
                    blocks: blocks
                ), step < maxSteps {
                    if !lastText.isEmpty {
                        messages.append(.assistant(lastText))
                    }
                    messages.append(.user(
                        "You claimed an Obsidian/vault write, but no tool result names obsidian_put_file (or that server's write tool) with status ok. Call mcp_call to write it, or retract the claim."
                    ))
                    continue
                }
                if !lastText.isEmpty {
                    messages.append(.assistant(lastText))
                }
                let unconfirmed = AgentCompletionGate.unconfirmedVaultWrite(
                    text: lastText,
                    messages: messages,
                    blocks: blocks
                )
                return loopResult(
                    text: lastText,
                    steps: step,
                    failed: unconfirmed,
                    failureReason: unconfirmed ? "claimed vault write without an ok tool result" : nil
                )
            }

            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: response.text.isEmpty ? nil : response.text,
                    toolCalls: response.toolCalls
                )
            )

            let results = try await executeCalls(
                response.toolCalls,
                onTool: onTool,
                execute: execute
            )
            var disabledThisStep: [String] = []
            for (call, result) in zip(response.toolCalls, results) {
                blocks.append(contentsOf: result.blocks)
                let raw = result.output.isEmpty ? "(empty tool result)" : result.output
                var output = (call.name != "mcp_list_tools" && raw.count > 3_500)
                    ? ContextCompactor.summarizePayload(raw, head: 2_000, tail: 1_000)
                    : raw
                let vision = LLMRouting.supportsVisionImages(
                    provider: request.endpoint.provider,
                    model: request.endpoint.model
                )
                if result.imageJPEGBase64 != nil, !vision {
                    output += "\n[screenshot captured as pixels; this model cannot view images — use accessibility/UI text from the tool result.]"
                }
                messages.append(ChatMessage.tool(id: call.id, content: output))
                if let jpeg = result.imageJPEGBase64, vision {
                    messages.append(
                        ChatMessage(
                            role: "user",
                            content: "Screenshot from \(call.name).",
                            imageJPEGBase64: jpeg
                        )
                    )
                }
                if nameIsWeb(call.name) {
                    if isFailedWeb(output: result.output) {
                        webFails += 1
                    } else {
                        webFails = 0
                    }
                }
                if DisabledBuiltinFallback.isDisabledResult(result.output) {
                    disabledThisStep.append(call.name)
                }
                if call.name == "mcp_call" || call.name == "mcp_list_tools" {
                    if McpGatewayCall.isDeadEnd(result.output) {
                        mcpDeadEnds += 1
                    } else {
                        mcpDeadEnds = 0
                    }
                }
                if !result.promotedMcpTools.isEmpty {
                    let newcomers = result.promotedMcpTools.filter { promo in
                        !tools.contains(where: { $0.function.name == promo.chatName })
                    }
                    if !newcomers.isEmpty {
                        tools.append(contentsOf: McpCatalogPromote.chatTools(from: newcomers))
                        let names = newcomers.map(\.chatName).prefix(8).joined(separator: ", ")
                        messages.append(.user(
                            "First-class MCP tools are now available this turn: \(names). Call them directly by name with their arguments — do not wrap in mcp_call, toolport_call_tool, or call_tool_by_name."
                        ))
                    }
                }
                if !result.loadedSkillBodies.isEmpty {
                    for skill in result.loadedSkillBodies {
                        messages.append(.user("Loaded skill \(skill.id):\n\n\(skill.body)"))
                    }
                }
                if result.endTurn {
                    let text = result.output.isEmpty ? lastText : result.output
                    return loopResult(
                        text: text.isEmpty ? "Done." : text,
                        steps: step
                    )
                }
                if let nextPause = result.pause {
                    pause = nextPause
                    let text = lastText.isEmpty ? "Waiting on you to continue." : lastText
                    return loopResult(
                        text: text,
                        steps: step
                    )
                }
            }
            if !disabledThisStep.isEmpty, hasMcpTools {
                messages.append(.user(
                    DisabledBuiltinFallback.loopNudge(
                        tools: disabledThisStep,
                        context: McpFallbackContext.from(tools: tools)
                    )
                ))
            }
            if webFails >= 3, tools.contains(where: { $0.function.name == "web_search" || $0.function.name == "web_fetch" }) {
                tools.removeAll { $0.function.name == "web_search" || $0.function.name == "web_fetch" }
                messages.append(.user(
                    "Web search and fetch failed \(webFails) times. Those tools are disabled for the rest of this turn. Answer from this Mac (Settings → Connections → Keys, files, skills) or say you could not reach the web."
                ))
            }
            if !warnedMcpStall, mcpDeadEnds >= 3 {
                warnedMcpStall = true
                messages.append(.user(
                    "MCP hit repeated dead ends (expired cursor, no route, missing args, or connection failure). Stop retrying the same call. Fix args from the last recovery hint, use a different enabled MCP server, use web_search/web_fetch/write_file if enabled, or finish from data you already have."
                ))
            }
            if mcpDeadEnds >= 5, tools.contains(where: { $0.function.name == "mcp_call" || $0.function.name == "mcp_list_tools" }) {
                tools.removeAll { $0.function.name == "mcp_call" || $0.function.name == "mcp_list_tools" }
                messages.append(.user(
                    "MCP tools are disabled for the rest of this turn after \(mcpDeadEnds) gateway dead ends. Finish with web_search, write_file, or a direct answer. Do not call mcp_call again."
                ))
            }
        }

        let budgetText = lastText.isEmpty
            ? "I reached the step budget for this turn. Ask me to continue — I'll keep the full tool transcript."
            : lastText
        return loopResult(
            text: budgetText,
            steps: maxSteps,
            failed: true,
            failureReason: "step budget"
        )
    }

    private static func executeCalls(
        _ calls: [LLMToolCall],
        onTool: (@Sendable (String, String, AgentToolCallResult) -> Void)?,
        execute: @escaping @Sendable (String, String) async -> AgentToolCallResult
    ) async throws -> [AgentToolCallResult] {
        let uniqueIndexes = uniqueCallIndexes(calls)
        if calls.count > 1, calls.allSatisfy({ parallelSafeTools.contains($0.name) }) {
            return try await withThrowingTaskGroup(of: (Int, AgentToolCallResult).self) { group in
                for index in uniqueIndexes {
                    let call = calls[index]
                    group.addTask {
                        if Task.isCancelled { throw CancellationError() }
                        let result = await execute(call.name, call.arguments)
                        return (index, result)
                    }
                }
                var ordered = Array(repeating: AgentToolCallResult(output: ""), count: calls.count)
                for try await (index, result) in group {
                    ordered[index] = result
                    onTool?(calls[index].name, calls[index].arguments, result)
                }
                fillDuplicateResults(calls: calls, uniqueIndexes: uniqueIndexes, into: &ordered)
                return ordered
            }
        }
        var out: [AgentToolCallResult] = []
        var paused = false
        var seen: [String: AgentToolCallResult] = [:]
        for call in calls {
            if Task.isCancelled { throw CancellationError() }
            if paused {
                let skipped = AgentToolCallResult(output: "Skipped — waiting on earlier approval.")
                out.append(skipped)
                continue
            }
            let key = callFingerprint(call)
            if seen[key] != nil {
                out.append(AgentToolCallResult(
                    output: "Skipped duplicate \(call.name) with the same arguments this step. Use the earlier result."
                ))
                continue
            }
            let result = await execute(call.name, call.arguments)
            seen[key] = result
            onTool?(call.name, call.arguments, result)
            out.append(result)
            if result.pause != nil { paused = true }
        }
        return out
    }

    private static func callFingerprint(_ call: LLMToolCall) -> String {
        let args = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return call.name + "\n" + args
    }

    private static func uniqueCallIndexes(_ calls: [LLMToolCall]) -> [Int] {
        var seen = Set<String>()
        var indexes: [Int] = []
        for (index, call) in calls.enumerated() {
            if seen.insert(callFingerprint(call)).inserted {
                indexes.append(index)
            }
        }
        return indexes
    }

    private static func fillDuplicateResults(
        calls: [LLMToolCall],
        uniqueIndexes: [Int],
        into ordered: inout [AgentToolCallResult]
    ) {
        let uniqueSet = Set(uniqueIndexes)
        for (index, call) in calls.enumerated() where !uniqueSet.contains(index) {
            ordered[index] = AgentToolCallResult(
                output: "Skipped duplicate \(call.name) with the same arguments this step. Use the earlier result."
            )
        }
    }

    private static func nameIsWeb(_ name: String) -> Bool {
        name == "web_search" || name == "web_fetch"
    }

    private static func isFailedWeb(output: String) -> Bool {
        let lowered = output.lowercased()
        if lowered.hasPrefix("no results") { return true }
        if lowered.hasPrefix("search failed") || lowered.hasPrefix("search was blocked") { return true }
        if lowered.hasPrefix("fetch failed") { return true }
        if lowered.contains("do not retry") { return true }
        return false
    }
}
