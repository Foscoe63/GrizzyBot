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

    @Test("connected reads status active")
    func connectedStatus() {
        let value: [String: Any] = [
            "results": [
                "gmail": ["status": "active"],
            ],
        ]
        #expect(ComposioClient.connected(in: value, toolkit: "gmail"))
        #expect(!ComposioClient.connected(in: value, toolkit: "slack"))
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
