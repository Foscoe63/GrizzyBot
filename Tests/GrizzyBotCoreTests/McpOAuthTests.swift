import Testing
import Foundation
@testable import GrizzyBotCore

@Suite struct McpOAuthTests {
    @Test func pkceMatchesRFCVector() {
        // RFC 7636 appendix B
        #expect(McpOAuth.pkceChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func parsesResourceMetadata() {
        let h = #"Bearer realm="mcp", resource_metadata="https://x.example/.well-known/oauth-protected-resource""#
        #expect(McpOAuth.resourceMetadataURL(from: h)?.absoluteString == "https://x.example/.well-known/oauth-protected-resource")
        #expect(McpOAuth.resourceMetadataURL(from: "Bearer") == nil)
    }

    @Test func authorizationURLCarriesPKCEAndResource() throws {
        let u = try #require(McpOAuth.authorizationURL(
            endpoint: "https://a.example/authorize", clientId: "c", redirectURI: "http://127.0.0.1:5/callback",
            challenge: "ch", state: "st", resource: "https://m.example/mcp", scope: "read"))
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        #expect(v("code_challenge_method") == "S256")
        #expect(v("resource") == "https://m.example/mcp")
        #expect(v("state") == "st")
    }

    @Test func parsesCallback() {
        let r = McpOAuth.parseCallback(requestLine: "GET /callback?code=abc&state=xyz HTTP/1.1")
        #expect(r.code == "abc" && r.state == "xyz" && r.error == nil)
        #expect(McpOAuth.parseCallback(requestLine: "GET /callback?error=access_denied HTTP/1.1").error == "access_denied")
    }

    @Test func tokenParsingKeepsOldRefreshAndExpiry() throws {
        let body = Data(#"{"access_token":"at","expires_in":3600}"#.utf8)
        let t = try McpOAuth.tokens(fromResponse: body, clientId: "c", tokenEndpoint: "t", resource: "r", previousRefresh: "old")
        #expect(t.refreshToken == "old")
        #expect(t.isFresh())
        #expect(!t.isFresh(now: Date().addingTimeInterval(3600)))
        #expect(throws: McpError.self) {
            try McpOAuth.tokens(fromResponse: Data("{}".utf8), clientId: "c", tokenEndpoint: "t", resource: "r", previousRefresh: nil)
        }
    }

    @Test func serverKeyDropsQuery() {
        #expect(McpOAuth.serverKey(URL(string: "https://m.example/mcp?x=1")!) == "https://m.example/mcp")
    }
}
