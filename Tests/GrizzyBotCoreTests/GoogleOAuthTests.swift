import Foundation
import GrizzyBotCore
import Testing

@Suite("Google OAuth")
struct GoogleOAuthTests {
    @Test("Google plugin slug detection")
    func googleSlugs() {
        #expect(GoogleOAuth.isGooglePlugin("gmail"))
        #expect(GoogleOAuth.isGooglePlugin("google-calendar"))
        #expect(GoogleOAuth.isGooglePlugin("googlecalendar"))
        #expect(GoogleOAuth.isGooglePlugin("google-sheets"))
        #expect(GoogleOAuth.isGooglePlugin("google-drive"))
        #expect(GoogleOAuth.isGooglePlugin("google-docs"))
        #expect(!GoogleOAuth.isGooglePlugin("slack"))
        #expect(!GoogleOAuth.isGooglePlugin("composio_connect"))
    }

    @Test("scopes cover mail calendar sheets docs drive")
    func scopes() {
        let gmail = GoogleOAuth.scopes(for: "gmail")
        #expect(gmail.contains(where: { $0.contains("gmail") }))
        #expect(gmail.contains(where: { $0.contains("userinfo.email") }))

        let calendar = GoogleOAuth.scopes(for: "google-calendar")
        #expect(calendar.contains(where: { $0.contains("calendar") }))

        let all = GoogleOAuth.scopes(for: GoogleOAuth.allGoogleSlugs)
        #expect(all.contains(where: { $0.contains("gmail") }))
        #expect(all.contains(where: { $0.contains("calendar") }))
        #expect(all.contains(where: { $0.contains("spreadsheets") }))
        #expect(all.contains(where: { $0.contains("documents") }))
        #expect(all.contains(where: { $0.contains("drive") }))
    }

    @Test("authorization URL includes offline access and PKCE")
    func authURL() throws {
        let url = try GoogleOAuth.authorizationURL(
            clientId: "client.apps.googleusercontent.com",
            redirectURI: GoogleOAuth.loopbackRedirectURI,
            scopes: ["https://www.googleapis.com/auth/gmail.readonly", "openid"],
            state: "abc123",
            codeChallenge: "challenge_value"
        )
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "client.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "http://127.0.0.1:8765")
        #expect(GoogleOAuth.loopbackRedirectURI == "http://127.0.0.1:8765")
        #expect(!GoogleOAuth.loopbackRedirectURI.hasSuffix("/"))
        #expect(items["response_type"] == "code")
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["state"] == "abc123")
        #expect(items["code_challenge"] == "challenge_value")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["scope"]?.contains("gmail.readonly") == true)
    }

    @Test("parse token response keeps refresh and expiry")
    func parseToken() throws {
        let json = """
        {
          "access_token": "ya29.a0",
          "expires_in": 3600,
          "refresh_token": "1//refresh",
          "scope": "https://www.googleapis.com/auth/gmail.readonly openid",
          "token_type": "Bearer"
        }
        """
        let cred = try GoogleOAuth.parseTokenResponse(Data(json.utf8), existingRefresh: nil)
        #expect(cred.access == "ya29.a0")
        #expect(cred.refresh == "1//refresh")
        #expect(cred.tokenType == "Bearer")
        #expect(cred.scopes.contains(where: { $0.contains("gmail") }))
        #expect(cred.expires > Date().timeIntervalSince1970)
    }

    @Test("parse callback extracts code and rejects bad state")
    func parseCallback() throws {
        let ok = try GoogleOAuth.parseCallbackPath(
            "/?code=4/abc&state=expected",
            expectedState: "expected"
        )
        #expect(ok == "4/abc")
        #expect(throws: GoogleOAuthError.self) {
            try GoogleOAuth.parseCallbackPath("/?code=4/abc&state=wrong", expectedState: "expected")
        }
        #expect(throws: GoogleOAuthError.self) {
            try GoogleOAuth.parseCallbackPath("/?error=access_denied&state=expected", expectedState: "expected")
        }
    }

    @Test("setup guide has ordered Cloud Console steps")
    func setupGuide() {
        let steps = GoogleOAuth.setupGuide
        #expect(steps.count >= 5)
        #expect(steps[0].title.lowercased().contains("cloud"))
        #expect(steps.contains(where: { $0.body.lowercased().contains("gmail") }))
        #expect(steps.contains(where: { $0.body.lowercased().contains("calendar") }))
        #expect(steps.contains(where: { $0.body.contains("http://127.0.0.1:8765") }))
        #expect(steps.contains(where: { $0.linkURL != nil }))
    }

    @Test("pkce challenge is base64url sha256")
    func pkce() {
        let verifier = GoogleOAuth.makeCodeVerifier()
        #expect(verifier.count >= 43)
        let challenge = GoogleOAuth.codeChallengeS256(verifier: verifier)
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
        #expect(!challenge.contains("="))
    }
}
