import Foundation
import GrizzyBotCore
import Testing

@Suite("Composio")
struct ComposioTests {
    @Test("toolkitSlug strips dashes and underscores")
    func toolkitSlug() {
        #expect(ComposioClient.toolkitSlug("google-calendar") == "googlecalendar")
        #expect(ComposioClient.toolkitSlug("Google_Sheets") == "googlesheets")
        #expect(ComposioClient.toolkitSlug("gmail") == "gmail")
        #expect(ComposioClient.toolkitSlug("x") == "twitter")
        #expect(ComposioClient.toolkitSlug("twitter") == "twitter")
        #expect(ComposioClient.toolkitSlug("X_Twitter") == "twitter")
    }

    @Test("auth-apps add URLs are treated as Composio setup links")
    func authConfigSetupURL() {
        let setup = URL(string: "https://backend.composio.dev/api/v1/auth-apps/add")!
        let oauth = URL(string: "https://connect.composio.dev/link/abc")!
        #expect(ComposioClient.isAuthConfigSetupURL(setup))
        #expect(!ComposioClient.isAuthConfigSetupURL(oauth))
        #expect(ComposioClient.requiresCustomAuthConfig("x"))
        #expect(ComposioClient.requiresCustomAuthConfig("twitter"))
        #expect(!ComposioClient.requiresCustomAuthConfig("gmail"))
    }

    @Test("parseAuthConfigIds prefers custom configs")
    func parseAuthConfigIds() throws {
        let data = """
        {"items":[
          {"id":"ac_managed","type":"default","toolkit":{"slug":"twitter"}},
          {"id":"ac_custom","type":"custom","toolkit":{"slug":"twitter"}}
        ]}
        """.data(using: .utf8)!
        #expect(ComposioClient.parseAuthConfigIds(data) == ["ac_custom", "ac_managed"])
    }

    @Test("parseMCP JSON result content")
    func parseJSON() throws {
        let raw = """
        {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\\"ok\\":true}"}]}}
        """
        let parsed = try ComposioClient.parseMCP(raw)
        let object = try #require(parsed as? [String: Any])
        #expect(object["ok"] as? Bool == true)
    }

    @Test("parseMCP SSE data line")
    func parseSSE() throws {
        let raw = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello"}]}}

        """
        let parsed = try ComposioClient.parseMCP(raw)
        let object = try #require(parsed as? [String: Any])
        #expect(object["text"] as? String == "hello")
    }

    @Test("firstAuthURL picks a Composio connect link")
    func authURL() {
        let value: [String: Any] = [
            "redirect": "https://example.com/ignore",
            "auth": "https://connect.composio.dev/auth/gmail?session=1",
        ]
        let url = ComposioClient.firstAuthURL(in: value)
        #expect(url?.absoluteString.contains("composio") == true)
    }

    @Test("preferredReadTool picks fetch emails over attachment/thread helpers")
    func preferredReadTool() {
        let tools = [
            "GMAIL_GET_ATTACHMENT",
            "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
            "COMPOSIO_GET_TOOL_SCHEMAS",
            "GMAIL_FETCH_EMAILS",
            "GMAIL_SEND_EMAIL",
        ]
        #expect(ComposioClient.preferredReadTool(in: tools, toolkit: "gmail") == "GMAIL_FETCH_EMAILS")
        #expect(ComposioClient.readToolScore("GMAIL_FETCH_EMAILS", toolkit: "gmail")
            > ComposioClient.readToolScore("GMAIL_GET_ATTACHMENT", toolkit: "gmail"))
    }

    @Test("shortFailure extracts a one-line Composio error")
    func shortFailure() {
        let value: [String: Any] = [
            "successful": false,
            "data": [
                "error_count": 1,
                "results": [[
                    "tool_slug": "GMAIL_GET_ATTACHMENT",
                    "error": "Invalid request data provided\n- Missing message_id",
                ]],
            ],
        ]
        let text = ComposioClient.shortFailure(value, tool: "GMAIL_GET_ATTACHMENT")
        #expect(text.contains("GMAIL_GET_ATTACHMENT"))
        #expect(text.contains("Invalid request"))
        #expect(!text.contains("Missing message_id") || text.count < 200)
    }

    @Test("chatSummary keeps plugin cards short")
    func chatSummary() {
        let ok = ComposioClient.chatSummary(
            slug: "gmail",
            query: "in:inbox",
            result: "• Hello — a@b.com\n• World — c@d.com",
            failed: false
        )
        #expect(ok == "2 results · in:inbox")
        let fail = ComposioClient.chatSummary(
            slug: "gmail",
            query: "",
            result: "GMAIL_GET_ATTACHMENT: Invalid request data provided",
            failed: true
        )
        #expect(fail.count <= 160)
    }

    @Test("formatToolResult prefers subject lines over raw JSON")
    func formatToolResult() {
        let value: [String: Any] = [
            "data": [
                "messages": [
                    ["subject": "Invoice", "from": "billing@example.com"],
                    ["subject": "Hello", "from": "friend@example.com"],
                ],
            ],
        ]
        let text = ComposioClient.formatToolResult(value, tool: "GMAIL_FETCH_EMAILS")
        #expect(text.contains("Invoice"))
        #expect(text.contains("Hello"))
        #expect(!text.contains("\"data\""))
    }

    @Test("multipleAccountChoices parses Composio multi-account error")
    func multipleAccounts() {
        let value: [String: Any] = [
            "successful": false,
            "data": [
                "error_count": 1,
                "results": [[
                    "error": "Multiple gmail accounts connected. Specify which to use via the 'account' field:\n- \"gmail_dayal-peiser\"\n- \"gmail_lerwa-gharry\"",
                ]],
            ],
        ]
        let names = ComposioClient.multipleAccountChoices(in: value)
        #expect(names == ["gmail_dayal-peiser", "gmail_lerwa-gharry"])
        #expect(ComposioClient.resolveAccountChoice(requested: "lerwa-gharry", available: names ?? []) == "gmail_lerwa-gharry")
        #expect(ComposioClient.resolveAccountChoice(requested: "gmail_lerwa-gharry", available: names ?? []) == "gmail_lerwa-gharry")
        #expect(ComposioClient.isFailedExecution(value))
    }

    @Test("connected reads modern ACTIVE + data.results wrapper")
    func connectedActiveUppercase() {
        let value: [String: Any] = [
            "data": [
                "message": "ok",
                "results": [
                    "gmail": [
                        "status": "ACTIVE",
                        "connected_account_id": "ca_123",
                    ],
                    "googlecalendar": [
                        "status": "INITIATED",
                        "redirect_url": "https://connect.composio.dev/auth/googlecalendar",
                    ],
                ],
                "summary": [
                    "active_connections": 1,
                    "initiated_connections": 1,
                ],
            ],
            "successful": true,
        ]
        #expect(ComposioClient.connected(in: value, toolkit: "gmail"))
        #expect(!ComposioClient.connected(in: value, toolkit: "googlecalendar"))
    }

    @Test("connected is false when only a redirect_url is present")
    func connectedRedirectOnly() {
        let value: [String: Any] = [
            "data": [
                "results": [
                    "gmail": [
                        "redirect_url": "https://connect.composio.dev/link/abc",
                    ],
                ],
            ],
        ]
        #expect(!ComposioClient.connected(in: value, toolkit: "gmail"))
    }

    @Test("manageConnectionsArgs uses toolkit string list")
    func manageConnectionsArgs() {
        let args = ComposioClient.manageConnectionsArgs(toolkits: ["gmail", "googlecalendar"])
        let toolkits = args["toolkits"] as? [String]
        #expect(toolkits == ["gmail", "googlecalendar"])
        #expect(args["reinitiate_all"] == nil)
    }

    @Test("catalog URL adds a search query")
    func catalogURL() throws {
        let plain = try #require(ComposioClient.catalogURL(backendURL: "https://backend.composio.dev/api/v3", query: ""))
        #expect(plain.absoluteString.contains("toolkits"))
        #expect(plain.absoluteString.contains("limit=200"))
        #expect(!plain.absoluteString.contains("search="))

        let searched = try #require(ComposioClient.catalogURL(
            backendURL: "https://backend.composio.dev/api/v3",
            query: " box "
        ))
        let items = URLComponents(url: searched, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(where: { $0.name == "search" && $0.value == "box" }))
    }

    @Test("parseCatalog reads Composio toolkit items")
    func parseCatalog() throws {
        let json = """
        {"items":[
          {"slug":"clickup","name":"ClickUp","description":"Tasks and docs","logo":"https://example.com/clickup.png"},
          {"key":"gmail","meta":{"description":"Mail","logo":"https://example.com/gmail.png"}}
        ]}
        """
        let items = try ComposioClient.parseCatalog(Data(json.utf8))
        #expect(items.count == 2)
        #expect(items[0].slug == "clickup")
        #expect(items[0].name == "ClickUp")
        #expect(items[0].blurb.contains("Tasks"))
        #expect(items[0].logo == "https://example.com/clickup.png")
        #expect(items[1].slug == "gmail")
        #expect(items[1].blurb == "Mail")
    }

    @Test("ImmediateComposio catalog filters by query")
    func immediateCatalogQuery() async throws {
        let composio = ImmediateComposio()
        composio.catalog = [
            ConnectionItem(slug: "gmail", name: "Gmail", blurb: "Mail"),
            ConnectionItem(slug: "clickup", name: "ClickUp", blurb: "Tasks"),
        ]
        let all = try await composio.listCatalog(query: "")
        #expect(all.count == 2)
        let filtered = try await composio.listCatalog(query: "click")
        #expect(filtered.map(\.slug) == ["clickup"])
    }
}
