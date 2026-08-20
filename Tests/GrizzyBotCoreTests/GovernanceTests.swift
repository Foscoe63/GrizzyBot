import Foundation
import GrizzyBotCore
import Testing

@Suite("Action policy")
struct ActionPolicyTests {
    @Test("deny beats allow; empty allow is fail-closed")
    func denyBeforeAllow() {
        let context = PolicyContext(toolName: "computer_click", botId: "b", actorId: "u", pageHost: "bank.example")
        let denied = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: [#"contains(page.host, "bank")"#], allow: ["true"]),
            context: context
        )
        #expect(!denied.allowed)
        #expect(!denied.forward)
        #expect(denied.source == .deny)

        let dry = ActionPolicyEngine.evaluate(
            ActionPolicy(mode: .dryRun, deny: [#"contains(page.host, "bank")"#], allow: ["true"]),
            context: context
        )
        #expect(!dry.allowed)
        #expect(dry.forward)

        let closed = ActionPolicyEngine.evaluate(ActionPolicy(deny: [], allow: []), context: context)
        #expect(!closed.allowed)
        #expect(closed.source == .default)

        let open = ActionPolicyEngine.evaluate(.openDefault, context: context)
        #expect(open.allowed)
        #expect(open.forward)
    }

    @Test("broken deny denies; broken allow does not permit")
    func failClosedExpressions() {
        let context = PolicyContext(toolName: "shell", botId: "b", actorId: "u")
        let deny = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: ["not a (valid"], allow: ["true"]),
            context: context
        )
        #expect(!deny.forward)

        let allow = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: [], allow: ["not a (valid"]),
            context: context
        )
        #expect(!allow.allowed)
        #expect(allow.source == .default)
    }

    @Test("MCP write intent and file rules")
    func mcpAndFile() {
        let write = PolicyContext(
            toolName: "mcp_call",
            botId: "b",
            actorId: "u",
            intent: .writeTool,
            mcp: PolicyMcp(server: "github", tool: "create_issue", effect: .write)
        )
        let decision = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: [#"intent == "write_tool""#], allow: ["true"]),
            context: write
        )
        #expect(!decision.forward)

        let env = PolicyContext(
            toolName: "read_file",
            botId: "b",
            actorId: "u",
            file: PolicyFile(path: "/tmp/secrets.env")
        )
        let blocked = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: [#"file.extension == "env""#], allow: ["true"]),
            context: env
        )
        #expect(!blocked.forward)
    }
}

@Suite("MCP catalog")
struct McpCatalogTests {
    @Test("unknown and custom are writes; github search is a read")
    func classify() {
        let github = McpServer(name: "GitHub", command: "/opt/homebrew/bin/github-mcp-server")
        #expect(McpCatalog.classify(server: github, toolName: "search_repositories", advertised: true) == .read)
        #expect(McpCatalog.classify(server: github, toolName: "create_issue", advertised: true) == .write)
        #expect(McpCatalog.classify(server: github, toolName: "mystery_tool", advertised: false) == .write)
        let custom = McpServer(name: "my-server", command: "npx whatever")
        #expect(McpCatalog.classify(server: custom, toolName: "list_things", advertised: true) == .write)
    }

    @Test("grants: empty family allows; once a grant exists, missing is deny")
    func grantMatrix() {
        let bot = "b1"
        let github = "mcp:gh"
        let slack = "mcp:slack"
        #expect(PluginGrant.allows(grants: [], botId: bot, plugin: github, tool: nil))
        let grants = [PluginGrant(botId: bot, plugin: github)]
        #expect(PluginGrant.allows(grants: grants, botId: bot, plugin: github, tool: "search_repositories"))
        #expect(!PluginGrant.allows(grants: grants, botId: bot, plugin: slack, tool: nil))
        let toolGrants = [PluginGrant(botId: bot, plugin: github, tool: "search_repositories")]
        #expect(PluginGrant.allows(grants: toolGrants, botId: bot, plugin: github, tool: "search_repositories"))
        #expect(!PluginGrant.allows(grants: toolGrants, botId: bot, plugin: github, tool: "create_issue"))
    }
}

@Suite("Audit redaction")
struct AuditRedactorTests {
    @Test("secrets become character counts")
    func redact() {
        let redacted = AuditRedactor.redact([
            "token": .string("sk-secret-value"),
            "label": .string("github"),
        ])
        if case .object(let object) = redacted["token"], case .number(let chars) = object["chars"] {
            #expect(Int(chars) == "sk-secret-value".count)
        } else {
            Issue.record("token should be chars-only")
        }
        #expect(redacted["label"] == .string("github"))
        let secret = AuditRedactor.secretRecord(label: "password", characterCount: 12)
        #expect(secret["chars"] == .number(12))
        #expect(secret["label"] == .string("password"))
    }
}

@Suite("Stall clock")
struct StallClockTests {
    @Test("silence is a stall; a touch resets it")
    func silence() {
        var clock = StallClock(stallMs: 50)
        #expect(!clock.isStalled(nowMs: 0))
        #expect(clock.isStalled(nowMs: 50))
        clock.touch(at: 40)
        #expect(!clock.isStalled(nowMs: 50))
        #expect(clock.isStalled(nowMs: 90))
        clock = StallClock(stallMs: 0)
        #expect(!clock.isStalled(nowMs: 10_000))
    }
}

@Suite("Knowledge ACL")
struct KnowledgePlaneTests {
    @Test("ungranted bots cannot search a source")
    func acl() {
        let source = KnowledgeSource(
            name: "Policies",
            kind: .folder,
            path: "/tmp",
            grantedBotIds: ["allowed"]
        )
        #expect(KnowledgePlane.sourcesVisible(to: "allowed", from: [source]).count == 1)
        #expect(KnowledgePlane.sourcesVisible(to: "other", from: [source]).isEmpty)
        let docs = [
            MemoryDocument(id: "1", scope: "knowledge", botId: source.id, path: "/tmp/a.md", content: "expense policy reimbursement"),
        ]
        let hits = KnowledgePlane.search(query: "expense", botId: "other", sources: [source], documents: docs)
        #expect(hits.isEmpty)
        let allowed = KnowledgePlane.search(query: "expense", botId: "allowed", sources: [source], documents: docs)
        #expect(!allowed.isEmpty)
    }
}

@Suite("AG-UI parser")
struct AguiParserTests {
    @Test("accumulates text and tool calls from SSE")
    func parse() throws {
        let lines = [
            #"data: {"type":"RUN_STARTED"}"#,
            #"data: {"type":"TEXT_MESSAGE_CONTENT","delta":"hello "}"#,
            #"data: {"type":"TEXT_MESSAGE_CONTENT","delta":"world"}"#,
            #"data: {"type":"TOOL_CALL_START","toolCallId":"c1","toolCallName":"web_search"}"#,
            #"data: {"type":"TOOL_CALL_ARGS","delta":"{\"query\":\"x\"}"}"#,
            #"data: {"type":"TOOL_CALL_END"}"#,
            #"data: {"type":"RUN_FINISHED"}"#,
        ]
        let response = try AguiClient.parseSSEForTests(lines)
        #expect(response.text == "hello world")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "web_search")
        #expect(response.toolCalls.first?.arguments.contains("query") == true)
    }

    @Test("STATE_SNAPSHOT, deltas, and the rest of the event set")
    func fullEventSet() throws {
        let lines = [
            #"data: {"type":"RUN_STARTED"}"#,
            #"data: {"type":"STEP_STARTED","stepName":"agent"}"#,
            #"data: {"type":"STATE_SNAPSHOT","snapshot":{"label":"open"}}"#,
            #"data: {"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#,
            #"data: {"type":"TEXT_MESSAGE_CONTENT","delta":"hi"}"#,
            #"data: {"type":"TEXT_MESSAGE_END","messageId":"m1"}"#,
            #"data: {"type":"STATE_DELTA","delta":{"flag":"yes"}}"#,
            #"data: {"type":"MESSAGES_SNAPSHOT","messages":[]}"#,
            #"data: {"type":"STEP_FINISHED"}"#,
            #"data: {"type":"RUN_FINISHED"}"#,
        ]
        let response = try AguiClient.parseSSEForTests(lines)
        #expect(response.text == "hi")
        #expect(response.state.objectValue()["label"] == .string("open"))
        #expect(response.state.objectValue()["flag"] == .string("yes"))
    }
}

@Suite("Action gateway")
struct ActionGatewayTests {
    @Test("Enter is activate; exclusive computer tools are identified")
    func intents() {
        #expect(ActionGateway.intent(tool: "computer_key", key: "Enter") == .activate)
        #expect(ActionGateway.intent(tool: "computer_key", key: "a") == .type)
        #expect(ActionGateway.isComputerTool("computer_click"))
        #expect(!ActionGateway.isComputerTool("read_file"))
        let ctx = ActionGateway.context(
            tool: "computer_open",
            argumentsJSON: #"{"url":"https://example.com/app"}"#,
            botId: "b",
            actorId: "u"
        )
        #expect(ctx.pageHost == "example.com")
        #expect(ctx.intent == .navigate)
    }

    @Test("click context carries the snapshot element, not a model label")
    func clickElementFromOutline() {
        let outline = ComputerOutline.format(lines: [
            ComputerOutline.line(tag: "button", title: "Submit", x: 10, y: 10, width: 80, height: 24),
        ])
        let hit = ComputerOutline.hit(outline: outline, x: 20, y: 18)
        #expect(hit?.name == "Submit")
        #expect(hit?.role == "button")
        let ctx = ActionGateway.context(
            tool: "computer_click",
            argumentsJSON: #"{"x":"20","y":"18"}"#,
            botId: "b",
            actorId: "u",
            element: hit
        )
        let denied = ActionPolicyEngine.evaluate(
            ActionPolicy(deny: [#"contains(element.name, "Submit")"#], allow: ["true"]),
            context: ctx
        )
        #expect(!denied.forward)
        let missed = ComputerOutline.hit(outline: outline, x: 900, y: 900)
        #expect(missed == nil)
    }
}

@Suite("Exclusive takeover")
@MainActor
struct ExclusiveTakeoverTests {
    @Test("computer actions are refused while a person drives")
    func refuseWhileDriving() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotGov-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.signUp(name: "A", email: "gov@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent")
        store.takeControl(botId: bot.id)
        #expect(store.computers[bot.id]?.controlHolder == .user)
        #expect(store.auditEvents.contains(where: { $0.type == .computerControlTaken }))

        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [LLMToolCall(id: "1", name: "computer_click", arguments: #"{"x":"1","y":"1"}"#)]
            ),
            ChatCompletionResponse(text: "I could not click."),
        ])
        store.send(botId: bot.id, text: "click the button")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let combined = store.threads[bot.id]?.messages.flatMap(\.blocks).compactMap { block -> String? in
            switch block {
            case .card(let lines): return lines.map(\.v).joined(separator: " ")
            case .text(let t): return t
            default: return nil
            }
        }.joined(separator: " ") ?? ""
        #expect(combined.contains("person is driving") || combined.contains("refused"))
        #expect(store.auditEvents.contains(where: { $0.type == .computerActionRefused }))
    }
}

@Suite("Click policy from snapshot")
@MainActor
struct ClickPolicyTests {
    @Test("contains(element.name, Submit) refuses a click on the snapshot hit")
    func denySubmit() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotClick-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.signUp(name: "A", email: "click@b.com", password: "password1") == nil)
        let bot = store.createBot(name: "Agent")
        store.boot(botId: bot.id, force: true)
        #expect(await store.waitForComputerState(botId: bot.id, state: .running))
        store.actionPolicy = ActionPolicy(deny: [#"contains(element.name, "Submit")"#], allow: ["true"])
        if var computer = store.computers[bot.id] {
            computer.lastOutline = ComputerOutline.format(lines: [
                ComputerOutline.line(tag: "button", title: "Submit", x: 10, y: 10, width: 80, height: 24),
            ])
            store.computers[bot.id] = computer
        }
        store.chatCompleter = QueueChatClient([
            ChatCompletionResponse(
                toolCalls: [LLMToolCall(id: "1", name: "computer_click", arguments: #"{"x":"20","y":"20"}"#)]
            ),
            ChatCompletionResponse(text: "I could not click Submit."),
        ])
        store.send(botId: bot.id, text: "click submit")
        #expect(await store.waitForRunCompletion(botId: bot.id))
        let combined = store.threads[bot.id]?.messages.flatMap(\.blocks).compactMap { block -> String? in
            switch block {
            case .card(let lines): return lines.map(\.v).joined(separator: " ")
            case .text(let t): return t
            default: return nil
            }
        }.joined(separator: " ") ?? ""
        #expect(combined.contains("Submit") || combined.contains("refused") || combined.contains("policy"))
        #expect(store.auditEvents.contains(where: { $0.type == .computerActionRefused && $0.matched?.contains("Submit") == true }))
    }
}

@Suite("Owner role")
@MainActor
struct OwnerRoleTests {
    @Test("first account is owner; later sign-up cannot save policy")
    func operatorCannotSavePolicy() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotRole-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.pluginClient = AlwaysAllowPlugins()
        #expect(store.isOwner)
        store.setActionPolicy(ActionPolicy(deny: ["true"], allow: []))
        #expect(store.actionPolicy.deny == ["true"])
        #expect(store.auditEvents.contains(where: { $0.type == .computerPolicyLoaded }))
        #expect(store.auditEvents.contains(where: { $0.type == .computerIsolationLoaded }))
        #expect(store.signUp(name: "Op", email: "op@b.com", password: "password1") == nil)
        #expect(!store.isOwner)
        store.setActionPolicy(.openDefault)
        #expect(store.actionPolicy.deny == ["true"])
    }
}

@Suite("Audit query")
struct AuditQueryTests {
    @Test("filters by type, allowed, and text")
    func query() {
        let events = [
            AuditEvent(type: .computerActionAllowed, actorId: "u", botId: "b1", tool: "computer_click", allowed: true, forwarded: true, reason: "Permitted by policy."),
            AuditEvent(type: .computerActionRefused, actorId: "u", botId: "b1", tool: "computer_click", allowed: false, forwarded: false, reason: "Submit blocked."),
            AuditEvent(type: .mcpCallRejected, actorId: "u", botId: "b2", tool: "mcp_call", allowed: false, forwarded: false, reason: "write tool"),
        ]
        let refused = AuditLog.query(events, AuditLog.Query(allowed: false, text: "submit"))
        #expect(refused.count == 1)
        #expect(refused.first?.reason.contains("Submit") == true)
        let byType = AuditLog.query(events, AuditLog.Query(type: .mcpCallRejected))
        #expect(byType.count == 1)
    }
}

@Suite("Published components")
struct PublishedComponentTests {
    @Test("drafts are unpublished; publish makes present_component legal")
    func publish() {
        let draft = SandboxComponent(id: "invoice", title: "Invoice", kind: "form", published: false)
        #expect(!AgentComponentCatalog.isPublished("invoice", extras: [draft]))
        var live = draft
        live.published = true
        #expect(AgentComponentCatalog.isPublished("invoice", extras: [live]))
        #expect(AgentComponentCatalog.isPublished("form", extras: []))
    }
}

@Suite("Knowledge plugin ingest")
struct KnowledgePluginTests {
    @Test("plugin search text becomes BM25 documents under the source ACL")
    func ingest() {
        let source = KnowledgeSource(name: "Drive", kind: .plugin, path: "google-drive", grantedBotIds: ["allowed"])
        let docs = KnowledgePlane.documents(from: "Q3 expense policy reimbursement", source: source)
        let hits = KnowledgePlane.search(query: "expense", botId: "allowed", sources: [source], documents: docs)
        #expect(!hits.isEmpty)
        let blocked = KnowledgePlane.search(query: "expense", botId: "other", sources: [source], documents: docs)
        #expect(blocked.isEmpty)
    }
}
