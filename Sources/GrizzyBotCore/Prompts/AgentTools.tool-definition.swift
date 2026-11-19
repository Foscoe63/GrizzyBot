import Foundation

// Tool names, descriptions and parameter schemas offered to the model.
// Execution and authorization live elsewhere. Rendering feeds `PromptVersion`.
extension AgentToolCatalog {
    private static func objectSchema(
        _ properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    private static func boolProp(_ description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description),
        ])
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    /// OpenAI/Anthropic function tools for a bot's enabled set.
    public static func chatTools(
        enabledIds: [String],
        mcpServers: [McpServer] = [],
        includeDelegation: Bool = true,
        skills: [AgentSkill] = [],
        promotedMcp: [McpPromotedTool] = [],
        mcpAdvertised: [String: [String]] = [:],
        externalAgents: [ExternalAgentSpec] = []
    ) -> [ChatTool] {
        let enabled = Set(enabledIds)
            .union(
                (enabledIds.contains("spawn_bot") || enabledIds.contains("message_bot"))
                    ? ["check_bot", "list_delegations", "stop_bot"] : []
            )
            .union(CanvasBoardStore.toolIds)
            .union(ArtifactStore.toolIds)
            .union(AgentToolCatalog.alwaysOnIds)
        var tools: [ChatTool] = []

        func add(_ id: String, name: String? = nil, description: String, properties: [String: JSONValue], required: [String]) {
            guard enabled.contains(id) else { return }
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: name ?? id,
                        description: description,
                        parameters: objectSchema(properties, required: required)
                    )
                )
            )
        }

        add(
            "write_file",
            description: "Write a UTF-8 file. Relative paths use the bot working folder when set, otherwise the bot home. Absolute/~ paths outside the working folder pause for approval.",
            properties: [
                "path": stringProp("Relative path (working folder or bot home) or absolute/~ path"),
                "content": stringProp("Full file contents"),
            ],
            required: ["path", "content"]
        )
        add(
            "read_file",
            description: "Read a UTF-8 file. Relative paths use the bot working folder when set, otherwise the bot home. Absolute/~ paths outside the working folder pause for approval.",
            properties: ["path": stringProp("Relative path (working folder or bot home) or absolute/~ path")],
            required: ["path"]
        )
        add(
            "edit_file",
            description: "Replace or append a file. Relative paths use the working folder when set, otherwise the bot home.",
            properties: [
                "path": stringProp("Relative path (working folder or bot home) or absolute/~ path"),
                "content": stringProp("New contents, or text to append"),
                "mode": .object([
                    "type": .string("string"),
                    "description": .string("replace (default) or append"),
                ]),
            ],
            required: ["path", "content"]
        )
        add(
            "move_file",
            description: "Move or rename a file. Relative paths use the working folder when set, otherwise the bot home.",
            properties: [
                "from": stringProp("Source path"),
                "to": stringProp("Destination path"),
            ],
            required: ["from", "to"]
        )
        add(
            "delete_file",
            description: "Delete a file or directory. Relative paths use the working folder when set, otherwise the bot home.",
            properties: ["path": stringProp("Relative path (working folder or bot home) or absolute/~ path")],
            required: ["path"]
        )
        add(
            "list_files",
            description: "List a directory. Empty lists the working folder when set, otherwise the bot home. Absolute/~ folders outside the working folder pause for approval.",
            properties: ["directory": stringProp("Relative directory, empty for the file root, or an absolute/~ path")],
            required: []
        )
        add(
            "meeting_notes",
            description: "Write meeting notes (summary, decisions, action items with owners, open questions, attendees) from a transcript: pass the transcript text, or the path of a .vtt/.srt/.txt transcript file. Long transcripts are handled in parts. This does not join meetings; it only works from a transcript the person provides.",
            properties: [
                "transcript": stringProp("The transcript text. Omit when giving a path."),
                "path": stringProp("Path to a transcript file (.vtt, .srt, .txt, .md)"),
                "title": stringProp("Meeting title, if known"),
            ],
            required: []
        )
        add(
            "web_search",
            description: "Search the public web. Use this for current facts, docs, and links.",
            properties: ["query": stringProp("Search query")],
            required: ["query"]
        )
        if enabled.contains("web_search") {
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "web_fetch",
                        description: "Fetch a public http(s) URL and return text (HTML stripped when possible).",
                        parameters: objectSchema(
                            ["url": stringProp("Absolute http or https URL")],
                            required: ["url"]
                        )
                    )
                )
            )
        }
        add(
            "shell",
            description: "Run a shell command with cwd in this bot's home. stdout/stderr are returned.",
            properties: [
                "command": stringProp("Command passed to zsh -lc"),
                "cwd": stringProp("Optional subdirectory of the bot home"),
                "timeout_seconds": stringProp("Optional timeout in seconds (5–300, default 120)"),
            ],
            required: ["command"]
        )
        add(
            "delegate_external",
            description: "Hand a coding job to an external coding agent (\(ExternalAgentSpec.all(custom: externalAgents).map(\.id).joined(separator: ", "))) that works inside the working folder. It is slower than doing small edits yourself; use it for multi-file code changes. access is read (look only) or edit (may change files); it can never run shell commands. Its answer comes from outside GrizzyBot, so check it.",
            properties: [
                "task": stringProp("The coding job, with the goal and any constraints"),
                "access": stringProp("read (default) or edit"),
                "agent": stringProp("Which agent to use; default \(ExternalAgentSpec.presets[0].id)"),
                "model": stringProp("Optional model for opencode as provider/model, e.g. lmstudio/<id> for a model loaded in LM Studio; default uses opencode's own configured model"),
            ],
            required: ["task"]
        )
        add(
            "shortcuts_list",
            description: "List the Shortcuts in the user's library by name. Call this before shortcuts_run rather than guessing a name.",
            properties: [:],
            required: []
        )
        add(
            "shortcuts_run",
            description: "Run one of the user's Shortcuts by name and return whatever it produces as text. Prefer this over driving the UI with the computer tools when a shortcut already does the job.",
            properties: [
                "name": stringProp("Exact shortcut name, as given by shortcuts_list"),
                "input": stringProp("Optional text passed to the shortcut as its input"),
                "timeout_seconds": stringProp("Optional timeout in seconds (5-300, default 120)"),
            ],
            required: ["name"]
        )
        add(
            "remember",
            description: "Store a durable fact in MEMORY.md (this bot) or SHARED.md (every bot). Similar facts are updated in place, not duplicated. Standing rules belong under ## Pin.",
            properties: [
                "content": stringProp("Fact to remember"),
                "scope": stringProp("bot, shared, or pin"),
                "pin": stringProp("true to store under ## Pin so it always loads"),
            ],
            required: ["content"]
        )
        if enabled.contains("remember") || enabled.contains("search_memory") || enabled.contains("forget") {
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "search_memory",
                        description: "Search this bot’s MEMORY.md and workspace SHARED.md. The prompt only has pins plus recent facts.",
                        parameters: objectSchema(
                            ["query": stringProp("Keywords to find")],
                            required: ["query"]
                        )
                    )
                )
            )
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "forget",
                        description: "Remove a durable fact that is wrong or outdated. Matches bullets in bot or shared memory.",
                        parameters: objectSchema(
                            [
                                "query": stringProp("Keywords that identify the fact to drop"),
                                "scope": stringProp("bot (default) or shared"),
                            ],
                            required: ["query"]
                        )
                    )
                )
            )
        }
        add(
            "search_sessions",
            description: "Search this bot's earlier conversations (all its chats and tasks) for something that was said. Use it when the person refers to past work you no longer see, e.g. \"what did we decide about the pricing page?\". Returns dated excerpts.",
            properties: ["query": stringProp("Keywords to find")],
            required: ["query"]
        )
        add(
            "search_knowledge",
            description: "Search knowledge sources this bot is granted (folders and plugin corpora). Respects per-bot ACLs.",
            properties: ["query": stringProp("Keywords to find")],
            required: ["query"]
        )
        add(
            "present_component",
            description: "Show a native component instead of only prose. id is form, gallery, activity, or refusals.",
            properties: [
                "id": stringProp("form, gallery, activity, or refusals"),
                "title": stringProp("Heading"),
                "fields": stringProp("JSON array of {id,label,value} for forms"),
                "items": stringProp("JSON array of strings for a gallery"),
            ],
            required: ["id"]
        )
        add(
            "report_decline",
            description: "Record that you declined a request without calling other tools. Used for the audit trail.",
            properties: ["reason": stringProp("Why you declined")],
            required: ["reason"]
        )
        add(
            "canvas_list",
            description: "List shared canvases on this Mac. Every bot can see the same boards.",
            properties: [:],
            required: []
        )
        add(
            "canvas_open",
            description: "Open a shared canvas in the GrizzyBot editor. Pass id or title from canvas_list. If the bot just took a screenshot, this places it on the board.",
            properties: ["id": stringProp("Canvas id or title")],
            required: []
        )
        add(
            "canvas_save",
            description: "Create or update a shared canvas. write_file cannot write these boards.",
            properties: [
                "id": stringProp("Existing canvas id or title to update"),
                "title": stringProp("Canvas name, e.g. Iran 2026-08-20"),
            ],
            required: []
        )
        add(
            "canvas_delete",
            description: "Delete a shared canvas by id or title.",
            properties: ["id": stringProp("Canvas id or title")],
            required: ["id"]
        )
        add(
            "canvas_place_image",
            description: "Place the latest computer screenshot (or a bot-home image path) onto a shared canvas. Creates a canvas if id is omitted.",
            properties: [
                "id": stringProp("Canvas id or title; omit to create one"),
                "title": stringProp("Name when creating a canvas"),
                "path": stringProp("Optional bot-home or absolute image path; default is the last screenshot"),
            ],
            required: []
        )
        add(
            "request_takeover",
            description: "Ask the user to take over the computer for login or human judgment.",
            properties: ["reason": stringProp("Why you need the user")],
            required: ["reason"]
        )
        add(
            "request_secret",
            description: "Ask the person for a key, token or password you need. They type it into a private field (or give a 1Password op:// reference); you never see the value. Afterwards write {{secret:NAME}} wherever the value belongs in a web_fetch, plugin_call or MCP tool argument and GrizzyBot fills it in. In a shell command it becomes an environment variable reference, so the value never appears in the command shown for approval. It cannot be used in file contents.",
            properties: [
                "name": stringProp("Short id such as GITHUB_TOKEN (letters, digits, _ . -)"),
                "purpose": stringProp("One sentence telling the person what it is for"),
            ],
            required: ["name", "purpose"]
        )
        add(
            "destination_write",
            description: "Write a record to a connected plugin (GitHub gist, Slack, Linear, …) and the local destination log.",
            properties: [
                "title": stringProp("Short title"),
                "body": stringProp("Body to write"),
                "slug": stringProp("Optional plugin slug, e.g. github"),
            ],
            required: ["title", "body"]
        )
        add(
            "computer_screenshot",
            description: "Capture a JPEG of this bot's live computer screen plus a text list of clickable Targets in the same pixel space. Use those coordinates for computer_click. The image is attached when the model can view images.",
            properties: [:],
            required: []
        )
        add(
            "computer_open",
            description: "Open a file:// or http(s) URL on the bot computer.",
            properties: ["url": stringProp("Absolute URL")],
            required: ["url"]
        )
        add(
            "computer_click",
            description: "Click at screenshot-pixel coordinates from the latest computer_screenshot (0,0 is top-left of that image). Prefer a Targets line from that screenshot. button=right for a context menu; count=2 for a double-click.",
            properties: [
                "x": stringProp("X pixel"),
                "y": stringProp("Y pixel"),
                "button": stringProp("left (default) or right"),
                "count": stringProp("1 (default) or 2 for double-click"),
            ],
            required: ["x", "y"]
        )
        add(
            "computer_scroll",
            description: "Scroll at screenshot-pixel coordinates. Positive delta scrolls down. Screenshot first so x,y match the image.",
            properties: [
                "x": stringProp("X pixel"),
                "y": stringProp("Y pixel"),
                "delta": stringProp("Pixels to scroll (default 120, negative for up)"),
            ],
            required: ["x", "y"]
        )
        add(
            "computer_type",
            description: "Type text into the computer (focused field or page).",
            properties: ["text": stringProp("Text to type")],
            required: ["text"]
        )
        add(
            "computer_key",
            description: "Press a key or chord on the computer (Enter, Escape, Tab, cmd+c, shift+enter).",
            properties: ["key": stringProp("Key name, e.g. Enter")],
            required: ["key"]
        )
        add(
            "plugin_call",
            description: "Call a connected plugin (gmail, google-calendar, github, x, …). For Gmail inbox/list: action=search (or list) with optional query like in:inbox or is:unread — do not invent thread_id/attachment ids. action=write sends mail (title=subject, body=text). If multiple Gmail accounts are linked, set account to one alias (gmail_lerwa-gharry) or account=all. Prefer Plugins → Account picker. For google-calendar: action=write creates an event — title=event name, body=JSON such as {\"day\":5,\"repeat\":\"monthly\"} for a day-of-month all-day event, or {\"start\":\"2026-10-05T09:00:00\",\"end\":\"2026-10-05T10:00:00\"} for a timed one. A successful write returns the Google event link, so if you do not see one it was not created. To READ a calendar, action=search with query as a time window, not a name: leave it empty, or pass today, tomorrow, this week, 2026-09-12, or 2026-09-01..2026-09-30 to list what is scheduled. A query that is not a date is a full-text title search, so do not pass the word primary expecting a listing. Each result ends with [eventId]; pass that to action=delete to remove one. JSON works too: {\"calendarId\":\"work@example.com\",\"timeMin\":\"2026-10-01\",\"timeMax\":\"2026-10-31\"}. Other Google writes, all with details as JSON in body: gmail sends mail and needs a recipient (title=subject, body={to, cc, bcc, body or html}) — prose alone is refused rather than sent nowhere; google-sheets appends rows (body={spreadsheetId, range, values}, or TSV/CSV); google-docs creates a document (title=name, body=text) and returns its link; google-drive uploads a file (title=name, body=contents). google-sheets reads real cell values when the query names a spreadsheet id, URL, or id!Range. For X/Twitter use slug x (twitter also works). Do not use slug composio_connect.",
            properties: [
                "slug": stringProp("Plugin slug, e.g. gmail, google-calendar, or x"),
                "action": stringProp("search, list, get, or write"),
                "query": stringProp("Search/list query for reads (optional; defaults to inbox for Gmail)"),
                "account": stringProp("Composio account alias, or all for every linked inbox"),
                "title": stringProp("Title for writes"),
                "body": stringProp("Body for writes"),
            ],
            required: ["slug"]
        )
        add(
            "artifact_create",
            description: "Create a shared artifact: a self-contained document, program, diagram, or app the user will keep, re-read, or run. Use it for substantial standalone content (over ~15 lines, or anything visual) — not for conversational answers, explanations, or short snippets, which belong in the reply. type is one of markdown, code, html, svg, mermaid, react. For code set language. react artifacts are JSX that must end with `export default function App() { … }`; they may import react and react-dom only, and Tailwind classes are available. Artifacts are shared across every bot on this Mac and survive restarts, so routines can create them too.",
            properties: [
                "id": stringProp("Short kebab-case id, e.g. morning-brief. Reused by artifact_update/artifact_rewrite"),
                "title": stringProp("Human title shown on the artifact"),
                "type": stringProp("markdown, code, html, svg, mermaid, or react"),
                "language": stringProp("Language for type=code, e.g. swift, python"),
                "content": stringProp("The full artifact contents"),
            ],
            required: ["title", "type", "content"]
        )
        add(
            "artifact_update",
            description: "Replace one exact passage inside an existing artifact, keeping the rest. old_str must appear EXACTLY once — include enough surrounding text to be unique, or the call is refused rather than guessing which occurrence you meant. Prefer this over artifact_rewrite for small edits; each call saves a new version.",
            properties: [
                "id": stringProp("Artifact id from artifact_create or artifact_list"),
                "old_str": stringProp("Exact text to replace, unique within the artifact"),
                "new_str": stringProp("Replacement text"),
            ],
            required: ["id", "old_str", "new_str"]
        )
        add(
            "artifact_rewrite",
            description: "Replace an artifact's entire contents. Use when the change is too broad for artifact_update. Saves a new version; earlier versions stay readable in the artifact panel.",
            properties: [
                "id": stringProp("Artifact id"),
                "content": stringProp("The complete new contents"),
                "title": stringProp("New title (optional)"),
            ],
            required: ["id", "content"]
        )
        add(
            "artifact_list",
            description: "List the artifacts on this Mac — id, title, type, and version count. Call this before updating an artifact whose id you do not have.",
            properties: [:],
            required: []
        )
        add(
            "artifact_read",
            description: "Read an artifact's current contents back. Use before editing one you did not create in this conversation, so old_str matches what is actually there.",
            properties: ["id": stringProp("Artifact id or exact title")],
            required: ["id"]
        )
        add(
            "artifact_delete",
            description: "Permanently delete an artifact and its version history. Only when the user asked for it.",
            properties: ["id": stringProp("Artifact id or exact title")],
            required: ["id"]
        )
        add(
            "import_skills",
            description: "Import every SKILL.md under a folder into GrizzyBot’s skill library so bots can use them. Path may be absolute (e.g. ~/.agents/skills) or inside the bot home.",
            properties: ["path": stringProp("Folder that contains SKILL.md files")],
            required: ["path"]
        )
        add(
            "routine_manage",
            description: "Make something run on a schedule, or look after this bot's scheduled routines. Use this whenever the person asks for a \"routine\", something that \"runs every …\", or \"N times a week\" — never crontab, launchd, or a script. Actions: create, list, pause, resume, delete. For create give a name, a prompt (what the bot should do each time, self-contained), and a schedule: cron (five fields, e.g. \"0 9 * * 1,3,5\") or days (\"mon,wed,fri\", \"weekdays\", \"daily\") plus time (\"9:00\", \"6:30 PM\"). Not more often than every 15 minutes. The person approves each new routine. A routine runs this bot with this bot's own tools.",
            properties: [
                "action": stringProp("create, list, pause, resume, or delete"),
                "name": stringProp("Routine name (create), or the routine to act on"),
                "prompt": stringProp("What to do on each run (create)"),
                "cron": stringProp("Cron schedule, five fields (create)"),
                "days": stringProp("Days instead of cron, e.g. mon,wed,fri or weekdays"),
                "time": stringProp("Time of day with days, e.g. 9:00 or 6:30 PM"),
                "id": stringProp("Routine id or name (pause, resume, delete)"),
            ],
            required: ["action"]
        )
        add(
            "config_manage",
            description: "Look up or change a few safe app settings for the person (appearance, menu bar, memory gate, queue mode, stall timeout, on-device privacy detection). Actions: list, get, set, history, revert. Every set or revert stops on an approval card the person must answer; never claim a change happened before they approve. Privacy rules, permissions, secrets and policies cannot be changed here.",
            properties: [
                "action": stringProp("list, get, set, history, or revert"),
                "key": stringProp("Setting key (get, set)"),
                "value": stringProp("New value (set)"),
                "id": stringProp("History id (revert)"),
            ],
            required: ["action"]
        )
        add(
            "workflow_run",
            description: "Run a saved workflow: a fixed graph of steps (tool calls, model questions, http requests) with typed inputs. Use action=list to see them, or pass id and input (an object). Steps run unattended and cannot wait for approvals.",
            properties: [
                "action": stringProp("list, or omit to run"),
                "id": stringProp("Workflow id or name"),
                "input": JSONValue.object(["type": .string("object"), "description": .string("Input values by name")]),
            ],
            required: []
        )
        add(
            "generate_image",
            description: "Create a picture on this Mac with Apple's on-device Image Playground, saved as a PNG in the bot home. Describe the picture in a sentence or two. Style: animation, illustration, or sketch. Nothing is sent off the Mac.",
            properties: [
                "prompt": stringProp("What the picture shows"),
                "style": stringProp("animation, illustration, or sketch"),
                "count": stringProp("How many variations, 1 to 4"),
            ],
            required: ["prompt"]
        )
        add(
            "skill_propose",
            description: "Propose a reusable skill from work you just did. It is saved switched off for the person to review and enable; you cannot enable it yourself. Only propose a repeatable procedure with no secrets or personal data.",
            properties: [
                "id": stringProp("Short kebab-case id, e.g. weekly-invoice-summary"),
                "description": stringProp("One line specific enough to pick this skill from a catalog"),
                "body": stringProp("Concise numbered steps naming the tools to use"),
                "keywords": stringProp("Optional comma-separated discovery keywords"),
            ],
            required: ["id", "description", "body"]
        )
        add(
            "capabilities_discover",
            description: "Search skills, builtins, and known MCP tools by keyword. Prefer this over guessing catalog names. Then call capabilities_load with matching ids.",
            properties: [
                "query": stringProp("What you need, e.g. gmail, obsidian, screenshot"),
                "top_k": stringProp("Max results (default 8)"),
            ],
            required: ["query"]
        )
        add(
            "capabilities_load",
            description: "Activate discovered capabilities by id (skills inject instructions; MCP tools become first-class). Pass comma-separated or JSON array of ids from capabilities_discover.",
            properties: [
                "ids": stringProp("Capability ids to load, e.g. research,gmail__messages_list"),
            ],
            required: ["ids"]
        )
        add(
            "todo",
            description: "Write or replace an OPTIONAL checklist for multi-step work (3+ steps). Each line must start with `- [ ]` or `- [x]`. Full-list replace each call.",
            properties: ["markdown": stringProp("Markdown checklist")],
            required: ["markdown"]
        )
        add(
            "complete",
            description: "Finish the current multi-step task with a one-paragraph summary, then stop.",
            properties: ["summary": stringProp("Short summary of what was done")],
            required: ["summary"]
        )
        add(
            "clarify",
            description: "Pause and ask the user a clarifying question before continuing.",
            properties: ["question": stringProp("Question for the user")],
            required: ["question"]
        )
        add(
            "propose_team_memory",
            description: "Suggest a durable fact for your department's shared team memory: a person, place, decision or term every bot in it should know. The person reviews it; nothing is shared until they accept. Reuse an existing note's key to correct it. Never include secrets.",
            properties: [
                "kind": stringProp("person, place, decision, or term"),
                "name": stringProp("Short title, e.g. a person's name or a decision's subject"),
                "detail": stringProp("The fact, its context and why it matters (about 600 characters at most)"),
                "aliases": stringProp("Other names for it, comma separated"),
                "key": stringProp("Optional stable key, to correct an existing note whose title changed"),
            ],
            required: ["kind", "name", "detail"]
        )
        add(
            "search_team_memory",
            description: "Search your department's accepted team notes, including ones the prompt did not have room for. Every word of the query must match.",
            properties: ["query": stringProp("Words to find")],
            required: ["query"]
        )
        if !skills.isEmpty {
            let ids = skills.map(\.id).joined(separator: ", ")
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "read_skill",
                        description: "Load the full instructions for a skill before you follow it. Skills: \(ids).",
                        parameters: objectSchema(
                            ["id": stringProp("Skill id from the catalog, e.g. research")],
                            required: ["id"]
                        )
                    )
                )
            )
        }
        if includeDelegation {
            add(
                "run_subagent",
                description: "Run a short-lived helper for this turn only. It is not a listed bot. Use spawn_bot to create a real bot.",
                properties: [
                    "name": stringProp("Short label, e.g. scout"),
                    "task": stringProp("Work the helper should complete"),
                    "instructions": stringProp("Optional extra instructions"),
                ],
                required: ["name", "task"]
            )
            add(
                "spawn_bot",
                description: "Create a full peer bot with its own thread, home, and memory. Appears in the bot list.",
                properties: [
                    "name": stringProp("Bot name"),
                    "title": stringProp("Short role title"),
                    "instructions": stringProp("Standing instructions for the new bot"),
                    "prompt": stringProp("Optional first task to run in the new bot's thread"),
                ],
                required: ["name"]
            )
            add(
                "message_bot",
                description: "Hand a task to a bot already listed in your roster. It works in its own thread; by default you wait and its answer comes back to you here. Prefer this over spawn_bot when a listed bot already does the job. Check each bot's [can: …] first: if it lacks a tool the job needs, hand the job to a bot that has it, or pass grant_tools.",
                properties: [
                    "name": stringProp("Name of the bot from the roster"),
                    "task": stringProp("What you want that bot to do, written as a full request"),
                    "wait": boolProp("Default true: wait for its answer and use it in your reply. Pass false only for long background jobs you are not going to report on this turn."),
                    "bot_id": stringProp("Optional bot id instead of the name"),
                    "grant_tools": stringProp("Optional, comma-separated: tools you have that the bot lacks and the job needs (shell, read_file, write_file, edit_file, list_files, web_search). Lent for this one job only; the person is asked first and approves each use."),
                    "anyway": boolProp("Pass true to send even though the bot lacks a tool the task seems to need."),
                ],
                required: ["name", "task"]
            )
            add(
                "check_bot",
                description: "Check on a bot you handed work to: its current status, what it is waiting on, and its latest reply. Use after a message_bot timeout or wait:false.",
                properties: [
                    "name": stringProp("Name of the bot from the roster"),
                    "bot_id": stringProp("Optional bot id instead of the name"),
                ],
                required: ["name"]
            )
            add(
                "stop_bot",
                description: "Stop a bot you handed work to when it is going the wrong way or must not finish what it is doing. Ends its current run now and tells it why. Only works on bots you messaged; it cannot stop anyone else.",
                properties: [
                    "name": stringProp("Name of the bot from the roster"),
                    "bot_id": stringProp("Optional bot id instead of the name"),
                    "reason": stringProp("Why it is being stopped; the bot reads this afterwards"),
                ],
                required: ["name"]
            )
            add(
                "list_delegations",
                description: "List the jobs you handed to other bots, newest first, with whether each is still running, answered, needs the user, or failed.",
                properties: [:],
                required: []
            )
            add(
                "delete_bot",
                description: "Permanently delete a bot this bot created. confirm_name must match exactly.",
                properties: [
                    "confirm_name": stringProp("Exact name of the bot to delete"),
                    "bot_id": stringProp("Optional bot id"),
                ],
                required: ["confirm_name"]
            )
        }

        let mcpEnabled = mcpServers.filter { enabled.contains($0.toolId) }
        if !mcpEnabled.isEmpty {
            let names = mcpEnabled.map(\.name).joined(separator: ", ")
            let hasGateway = mcpEnabled.contains { McpGatewayCall.isGateway($0) }
            let only = mcpEnabled.count == 1
            let omitHint = only
                ? "Omit server to use \(mcpEnabled[0].name)."
                : (hasGateway
                    ? "Always pass server=<name> unless calling a Toolport catalog tool (name contains __). Available: \(names)."
                    : "Always pass server=<name>. Do not omit server. Do not call Toolport unless that name is listed. Available: \(names).")
            let listDescription = hasGateway
                ? "List tools on an MCP server. Servers: \(names). \(omitHint) Toolport returns gateway meta-tools (status/search/call), not GitHub or Obsidian — search once, then mcp_call. Do not list the same server again this turn."
                : "List tools on an MCP server. Servers: \(names). \(omitHint) Call mcp_list_tools once, then mcp_call. Prefer first-class server__tool names already in your list. Do not list the same server again this turn."
            let callDescription = hasGateway
                ? "Call a tool on an MCP server. Servers: \(names). \(omitHint) `tool` is a name from mcp_list_tools, or a Toolport catalog name like github__search_repositories (wrapped for you). For toolport_call_tool, arguments.name must be non-empty — never id, never blank. Prefer filepath+content (path aliases to filepath). Do not call toolport_fetch_result after you already have results. Do not invent catalog names — search once if unsure."
                : "Call a tool on an MCP server. Servers: \(names). \(omitHint) Pass the MCP tool's own fields nested in arguments or as top-level parameters. path aliases to filepath. Prefer first-class server__tool tools already in your list over mcp_call."
            let serverProp = only
                ? "MCP server name or id; omit to use \(mcpEnabled[0].name)"
                : "MCP server name or id from: \(names). Required when more than one MCP is enabled."
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "mcp_list_tools",
                        description: listDescription,
                        parameters: objectSchema(
                            ["server": stringProp(serverProp)],
                            required: []
                        )
                    )
                )
            )
            tools.append(
                ChatTool(
                    function: ChatToolFunction(
                        name: "mcp_call",
                        description: callDescription,
                        parameters: objectSchema(
                            [
                                "server": stringProp(serverProp),
                                "tool": stringProp(
                                    hasGateway
                                        ? "MCP tool name, or a Toolport catalog name such as github__search_repositories"
                                        : "Tool name from mcp_list_tools"
                                ),
                                "arguments": .object([
                                    "type": .string("object"),
                                    "description": .string(
                                        hasGateway
                                            ? "Arguments for the MCP tool. Toolport call_tool needs non-empty name plus nested arguments (filepath/content, etc.)."
                                            : "Arguments object for the MCP tool"
                                    ),
                                ]),
                                "prompt": stringProp("Fallback text if the server expects a single prompt"),
                            ],
                            required: ["tool"]
                        )
                    )
                )
            )
        }

        var existingNames = Set(tools.map(\.function.name))
        let advertisedPromoted = McpCatalogPromote.fromAdvertised(
            servers: mcpEnabled,
            advertised: mcpAdvertised.mapValues(McpCatalogPromote.uniqueAdvertisedNames),
            reserved: existingNames.union(AgentToolCatalog.builtinIds)
        )
        var seeded: [String: McpPromotedTool] = [:]
        for promo in promotedMcp {
            seeded[promo.chatName] = promo
        }
        let combinedPromoted = McpCatalogPromote.merge(existing: seeded, adding: advertisedPromoted)
        let gatedPromoted = combinedPromoted.values.filter { promo in
            let advertised = mcpAdvertised[promo.serverId] ?? []
            return McpToolGate.isToolEnabled(
                enabledIds: enabledIds,
                serverId: promo.serverId,
                toolName: promo.executeTool,
                advertised: advertised
            )
        }
        .sorted { $0.chatName < $1.chatName }
        for promoted in McpCatalogPromote.chatTools(from: gatedPromoted) {
            guard !existingNames.contains(promoted.function.name) else { continue }
            existingNames.insert(promoted.function.name)
            tools.append(promoted)
        }

        return tools
    }
}
