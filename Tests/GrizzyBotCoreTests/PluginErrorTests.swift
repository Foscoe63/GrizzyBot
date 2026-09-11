import Foundation
import Testing
@testable import GrizzyBotCore

/// Google pretty-prints error JSON and reuses 403 for several unrelated causes.
/// These use real response bodies so the hint can never drift back to "reconnect for everything".
@Suite("Plugin API error messages")
struct PluginErrorTests {
    private func message(_ status: Int, _ json: String) -> String {
        PluginClient.apiErrorMessage(status: status, body: Data(json.utf8))
    }

    @Test("403 accessNotConfigured says enable the API, not reconnect")
    func apiDisabled() {
        let body = """
        {
          "error": {
            "code": 403,
            "message": "Gmail API has not been used in project 72548574866 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/gmail.googleapis.com/overview?project=72548574866 then retry.",
            "errors": [
              {
                "message": "Gmail API has not been used in project 72548574866 before or it is disabled.",
                "domain": "usageLimits",
                "reason": "accessNotConfigured"
              }
            ],
            "status": "PERMISSION_DENIED"
          }
        }
        """
        let out = message(403, body)
        #expect(out.contains("not enabled for your Google Cloud project"))
        #expect(out.contains("https://console.developers.google.com/apis/api/gmail.googleapis.com/overview?project=72548574866"))
        #expect(out.contains("do not need to sign in again"))
        // The old bug: this must never claim the sign-in expired.
        #expect(!out.localizedCaseInsensitiveContains("expired"))
        // The old bug: the body must not be truncated to "{".
        #expect(!out.hasSuffix(": {"))
        #expect(out.contains("Gmail API has not been used"))
    }

    @Test("401 still says the sign-in expired")
    func expired() {
        let body = """
        {
          "error": {
            "code": 401,
            "message": "Request had invalid authentication credentials. Expected OAuth 2 access token.",
            "status": "UNAUTHENTICATED"
          }
        }
        """
        let out = message(401, body)
        #expect(out.contains("expired"))
        #expect(out.contains("Sign in with Google"))
    }

    @Test("403 insufficient scope asks for re-consent, not an API enable")
    func insufficientScope() {
        let body = """
        {
          "error": {
            "code": 403,
            "message": "Request had insufficient authentication scopes.",
            "status": "PERMISSION_DENIED",
            "details": [
              { "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }
            ]
          }
        }
        """
        let out = message(403, body)
        #expect(out.contains("missing a required scope"))
        #expect(out.contains("re-consent"))
        #expect(!out.contains("not enabled for your Google Cloud project"))
    }

    @Test("rate limits are reported as rate limits")
    func rateLimited() {
        let body = """
        {
          "error": {
            "code": 403,
            "message": "User-rate limit exceeded.",
            "errors": [ { "reason": "userRateLimitExceeded" } ],
            "status": "PERMISSION_DENIED"
          }
        }
        """
        let out = message(403, body)
        #expect(out.contains("Rate limited"))
        #expect(!out.localizedCaseInsensitiveContains("expired"))
    }

    @Test("non-JSON and empty bodies degrade without crashing or lying")
    func malformed() {
        let html = message(500, "<html><body>Internal Server Error</body></html>")
        #expect(html.hasPrefix("HTTP 500"))
        #expect(!html.localizedCaseInsensitiveContains("expired"))

        let empty = PluginClient.apiErrorMessage(status: 502, body: Data())
        #expect(empty == "HTTP 502")
    }

    @Test("OAuth-style error bodies surface error_description")
    func oauthStyle() {
        let out = message(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        #expect(out.contains("Token has been expired or revoked"))
    }
}
