import CryptoKit
import Darwin
import Foundation
import Security

/// Direct Google OAuth (Client ID + Secret) so Gmail / Calendar / Sheets / Drive / Docs
/// can bypass Composio. Uses a fixed loopback redirect on this Mac.
public enum GoogleOAuth {
    public static let credentialSecretKey = "_google_oauth"
    public static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

    /// Fixed port so `redirect_uri` is stable and can be registered in Google Cloud Console.
    /// Format matches Google’s examples: no trailing slash.
    public static let loopbackPort: UInt16 = 8765
    public static let loopbackRedirectURI = "http://127.0.0.1:8765"

    public static func loopbackRedirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    public static let allGoogleSlugs = [
        "gmail",
        "google-calendar",
        "google-sheets",
        "google-docs",
        "google-drive",
    ]

    public static let setupGuide: [GoogleSetupStep] = [
        GoogleSetupStep(
            title: "Open Google Cloud Console",
            body: "Sign in with the Google account that owns Gmail / Calendar. Create a project (or pick an existing one) — one project can cover every Google app in GrizzyBot.",
            linkTitle: "console.cloud.google.com",
            linkURL: URL(string: "https://console.cloud.google.com/")
        ),
        GoogleSetupStep(
            title: "Enable the APIs you need",
            body: "APIs & Services → Library. Enable Gmail API, Google Calendar API, Google Sheets API, Google Docs API, and Google Drive API (skip any you do not use).",
            linkTitle: "API Library",
            linkURL: URL(string: "https://console.cloud.google.com/apis/library")
        ),
        GoogleSetupStep(
            title: "Configure the OAuth consent screen",
            body: "APIs & Services → OAuth consent screen. User type: External (or Internal for Workspace-only). App name: GrizzyBot. Add your Google account under Test users while the app is in Testing. Scopes can stay default for now — GrizzyBot requests them at sign-in.",
            linkTitle: "Consent screen",
            linkURL: URL(string: "https://console.cloud.google.com/apis/credentials/consent")
        ),
        GoogleSetupStep(
            title: "Create OAuth client + redirect URI",
            body: "Credentials → Create credentials → OAuth client ID. Prefer Desktop app. Then open the client → Authorized redirect URIs → Add URI and paste exactly: http://127.0.0.1:8765 (no trailing slash). Save. If your client has no redirect URI field, create a Web application client instead and add that same URI.",
            linkTitle: "Create credentials",
            linkURL: URL(string: "https://console.cloud.google.com/apis/credentials")
        ),
        GoogleSetupStep(
            title: "Copy Client ID and Client Secret",
            body: "Paste Client ID + Client secret into GrizzyBot Settings → Connections → Google. Save, then Plugins → Sign in with Google. One sign-in unlocks Gmail, Calendar, Sheets, Docs, and Drive. Error 400 redirect_uri_mismatch means http://127.0.0.1:8765 is missing from that client’s Authorized redirect URIs.",
            linkTitle: nil,
            linkURL: nil
        ),
    ]

    public static func isGooglePlugin(_ slug: String) -> Bool {
        let key = normalizeSlug(slug)
        return key == "gmail"
            || key == "googlecalendar"
            || key == "googlesheets"
            || key == "googledocs"
            || key == "googledrive"
            || key == "gdrive"
    }

    public static func normalizeSlug(_ slug: String) -> String {
        slug.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    public static func scopes(for slug: String) -> [String] {
        scopes(for: [slug])
    }

    public static func scopes(for slugs: [String]) -> [String] {
        var set: [String] = [
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
        ]
        for slug in slugs {
            switch normalizeSlug(slug) {
            case "gmail":
                appendUnique(&set, "https://www.googleapis.com/auth/gmail.modify")
            case "googlecalendar":
                appendUnique(&set, "https://www.googleapis.com/auth/calendar")
                appendUnique(&set, "https://www.googleapis.com/auth/calendar.events")
            case "googlesheets":
                appendUnique(&set, "https://www.googleapis.com/auth/spreadsheets")
            case "googledocs":
                appendUnique(&set, "https://www.googleapis.com/auth/documents")
            case "googledrive", "gdrive":
                appendUnique(&set, "https://www.googleapis.com/auth/drive")
            default:
                break
            }
        }
        return set
    }

    public static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public static func codeChallengeS256(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    public static func authorizationURL(
        clientId: String,
        redirectURI: String,
        scopes: [String],
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else { throw GoogleOAuthError.badURL }
        return url
    }

    public static func parseCallbackPath(_ pathAndQuery: String, expectedState: String) throws -> String {
        let raw = pathAndQuery.hasPrefix("http") ? pathAndQuery : "http://127.0.0.1\(pathAndQuery)"
        guard let comps = URLComponents(string: raw) else { throw GoogleOAuthError.badCallback }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        if let error = items["error"] {
            throw GoogleOAuthError.denied(error)
        }
        guard items["state"] == expectedState else { throw GoogleOAuthError.stateMismatch }
        guard let code = items["code"], !code.isEmpty else { throw GoogleOAuthError.badCallback }
        return code
    }

    public static func parseTokenResponse(_ data: Data, existingRefresh: String?) throws -> GoogleOAuthCredential {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleOAuthError.token("not JSON")
        }
        if let error = json["error"] as? String {
            let desc = (json["error_description"] as? String) ?? error
            throw GoogleOAuthError.token(desc)
        }
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw GoogleOAuthError.token("missing access_token")
        }
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? existingRefresh
            ?? ""
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
            ?? 3600
        let scope = (json["scope"] as? String) ?? ""
        let scopes = scope.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return GoogleOAuthCredential(
            access: access,
            refresh: refresh,
            expires: Date().timeIntervalSince1970 + expiresIn - 60,
            tokenType: (json["token_type"] as? String) ?? "Bearer",
            scopes: scopes,
            email: nil
        )
    }

    public static func encodeCredential(_ credential: GoogleOAuthCredential) -> String? {
        guard let data = try? JSONEncoder().encode(credential) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeCredential(_ raw: String?) -> GoogleOAuthCredential? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthCredential.self, from: data)
    }

    private static func appendUnique(_ list: inout [String], _ value: String) {
        if !list.contains(value) { list.append(value) }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct GoogleSetupStep: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public var title: String
    public var body: String
    public var linkTitle: String?
    public var linkURL: URL?

    public init(title: String, body: String, linkTitle: String? = nil, linkURL: URL? = nil) {
        self.title = title
        self.body = body
        self.linkTitle = linkTitle
        self.linkURL = linkURL
    }
}

public struct GoogleOAuthCredential: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String
    public var expires: TimeInterval
    public var tokenType: String
    public var scopes: [String]
    public var email: String?

    public init(
        access: String,
        refresh: String,
        expires: TimeInterval,
        tokenType: String = "Bearer",
        scopes: [String] = [],
        email: String? = nil
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.tokenType = tokenType
        self.scopes = scopes
        self.email = email
    }

    public var isExpired: Bool {
        Date().timeIntervalSince1970 >= expires
    }

    public func covers(scopes needed: [String]) -> Bool {
        let have = Set(scopes)
        return needed.allSatisfy { scope in
            scope == "openid" || have.contains(scope)
        }
    }
}

public enum GoogleOAuthError: Error, LocalizedError, Sendable, Equatable {
    case badURL
    case badCallback
    case stateMismatch
    case denied(String)
    case token(String)
    case missingCredentials
    case timeout
    case listener
    case portInUse

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Could not build the Google sign-in URL."
        case .badCallback: return "Google returned an incomplete callback."
        case .stateMismatch: return "Google sign-in state mismatch. Try again."
        case .denied(let reason): return "Google sign-in denied (\(reason))."
        case .token(let reason):
            if reason.localizedCaseInsensitiveContains("redirect_uri") {
                return "Google rejected the redirect URI. In Cloud Console → your OAuth client → Authorized redirect URIs, add exactly \(GoogleOAuth.loopbackRedirectURI) (no trailing slash), Save, wait ~1 minute, try again."
            }
            return "Google token error: \(reason)"
        case .missingCredentials: return "Add a Google Client ID and Client Secret in Settings → Connections → Google."
        case .timeout:
            return "Timed out waiting for Google sign-in. If the browser showed redirect_uri_mismatch, add exactly \(GoogleOAuth.loopbackRedirectURI) under Authorized redirect URIs for this Client ID, Save, then try again."
        case .listener: return "Could not start the local Google redirect listener on this Mac."
        case .portInUse:
            return "Port \(GoogleOAuth.loopbackPort) is in use. Quit whatever is using it, then try Sign in with Google again."
        }
    }
}

public protocol GoogleOAuthConnecting: Sendable {
    func authorize(clientId: String, clientSecret: String, scopes: [String]) async throws -> GoogleOAuthCredential
    func refresh(_ credential: GoogleOAuthCredential, clientId: String, clientSecret: String) async throws -> GoogleOAuthCredential
    func fetchEmail(accessToken: String) async throws -> String
    func revoke(token: String) async
}

/// Live Google OAuth using a short-lived loopback HTTP listener on 127.0.0.1.
public struct GoogleOAuthClient: GoogleOAuthConnecting, Sendable {
    public var openURL: @Sendable (URL) -> Void
    public var timeoutSeconds: TimeInterval

    public init(
        openURL: @escaping @Sendable (URL) -> Void = { _ in },
        timeoutSeconds: TimeInterval = 180
    ) {
        self.openURL = openURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func authorize(
        clientId: String,
        clientSecret: String,
        scopes: [String]
    ) async throws -> GoogleOAuthCredential {
        let trimmedId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedSecret.isEmpty else { throw GoogleOAuthError.missingCredentials }

        let state = GoogleOAuth.makeCodeVerifier()
        let verifier = GoogleOAuth.makeCodeVerifier()
        let challenge = GoogleOAuth.codeChallengeS256(verifier: verifier)
        let openURL = self.openURL
        let timeoutSeconds = self.timeoutSeconds
        // Never run the loopback socket on the MainActor — NWListener previously froze the UI.
        let loopback = try await Task.detached(priority: .userInitiated) {
            try await GoogleLoopback.waitForCode(
                expectedState: state,
                timeoutSeconds: timeoutSeconds
            ) { redirectURI in
                let url = try GoogleOAuth.authorizationURL(
                    clientId: trimmedId,
                    redirectURI: redirectURI,
                    scopes: scopes,
                    state: state,
                    codeChallenge: challenge
                )
                openURL(url)
            }
        }.value

        var request = URLRequest(url: GoogleOAuth.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code=\(urlEncode(loopback.code))",
            "client_id=\(urlEncode(trimmedId))",
            "client_secret=\(urlEncode(trimmedSecret))",
            "redirect_uri=\(urlEncode(loopback.redirectURI))",
            "grant_type=authorization_code",
            "code_verifier=\(urlEncode(verifier))",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GoogleOAuthError.token("HTTP \(status) \(text)")
        }
        var cred = try GoogleOAuth.parseTokenResponse(data, existingRefresh: nil)
        if let email = try? await fetchEmail(accessToken: cred.access) {
            cred.email = email
        }
        return cred
    }

    public func refresh(
        _ credential: GoogleOAuthCredential,
        clientId: String,
        clientSecret: String
    ) async throws -> GoogleOAuthCredential {
        guard !credential.refresh.isEmpty else { throw GoogleOAuthError.token("missing refresh_token") }
        var request = URLRequest(url: GoogleOAuth.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(urlEncode(clientId))",
            "client_secret=\(urlEncode(clientSecret))",
            "refresh_token=\(urlEncode(credential.refresh))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GoogleOAuthError.token("HTTP \(status) \(text)")
        }
        var next = try GoogleOAuth.parseTokenResponse(data, existingRefresh: credential.refresh)
        if next.scopes.isEmpty { next.scopes = credential.scopes }
        next.email = credential.email
        return next
    }

    public func fetchEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: GoogleOAuth.userInfoURL, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String,
              !email.isEmpty
        else {
            throw GoogleOAuthError.token("could not read Google account email")
        }
        return email
    }

    public func revoke(token: String) async {
        var request = URLRequest(url: GoogleOAuth.revokeURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(urlEncode(token))".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public final class ImmediateGoogleOAuth: GoogleOAuthConnecting, @unchecked Sendable {
    public var credential = GoogleOAuthCredential(
        access: "google-access",
        refresh: "google-refresh",
        expires: Date().timeIntervalSince1970 + 3600,
        scopes: GoogleOAuth.scopes(for: GoogleOAuth.allGoogleSlugs),
        email: "user@gmail.com"
    )
    public var lastScopes: [String] = []
    public var authorizeCalls = 0

    public init() {}

    public func authorize(clientId: String, clientSecret: String, scopes: [String]) async throws -> GoogleOAuthCredential {
        _ = clientId
        _ = clientSecret
        authorizeCalls += 1
        lastScopes = scopes
        var copy = credential
        copy.scopes = scopes
        return copy
    }

    public func refresh(
        _ credential: GoogleOAuthCredential,
        clientId: String,
        clientSecret: String
    ) async throws -> GoogleOAuthCredential {
        _ = clientId
        _ = clientSecret
        var next = credential
        next.access = "google-access-refreshed"
        next.expires = Date().timeIntervalSince1970 + 3600
        return next
    }

    public func fetchEmail(accessToken: String) async throws -> String {
        _ = accessToken
        return credential.email ?? "user@gmail.com"
    }

    public func revoke(token: String) async {
        _ = token
    }
}

// MARK: - Loopback listener (POSIX — never blocks the UI)

enum GoogleLoopback {
    struct Result: Sendable {
        var code: String
        var redirectURI: String
    }

    static func waitForCode(
        expectedState: String,
        timeoutSeconds: TimeInterval,
        onReady: @escaping @Sendable (String) throws -> Void
    ) async throws -> Result {
        let server = LoopbackServer()
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await server.serve(expectedState: expectedState, onReady: onReady)
                } onCancel: {
                    server.closeAll()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                server.closeAll()
                throw GoogleOAuthError.timeout
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                server.closeAll()
                return result
            } catch {
                group.cancelAll()
                server.closeAll()
                throw error
            }
        }
    }
}

private final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        if clientFD >= 0 {
            _ = Darwin.close(clientFD)
            clientFD = -1
        }
        if serverFD >= 0 {
            _ = Darwin.close(serverFD)
            serverFD = -1
        }
    }

    func serve(
        expectedState: String,
        onReady: @escaping @Sendable (String) throws -> Void
    ) async throws -> GoogleLoopback.Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GoogleLoopback.Result, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.blockingServe(expectedState: expectedState, onReady: onReady)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func blockingServe(
        expectedState: String,
        onReady: (String) throws -> Void
    ) throws -> GoogleLoopback.Result {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleOAuthError.listener }

        lock.lock()
        serverFD = fd
        lock.unlock()

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = GoogleOAuth.loopbackPort.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else {
            let err = errno
            closeAll()
            throw err == EADDRINUSE ? GoogleOAuthError.portInUse : GoogleOAuthError.listener
        }
        guard Darwin.listen(fd, 1) == 0 else {
            closeAll()
            throw GoogleOAuthError.listener
        }

        do {
            try onReady(GoogleOAuth.loopbackRedirectURI)
        } catch {
            closeAll()
            throw error
        }

        while true {
            lock.lock()
            let live = serverFD
            lock.unlock()
            if live < 0 { throw GoogleOAuthError.timeout }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&pfd, 1, 250)
            if polled < 0 {
                if errno == EINTR { continue }
                closeAll()
                throw GoogleOAuthError.listener
            }
            if polled == 0 { continue }

            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                closeAll()
                throw GoogleOAuthError.timeout
            }
            lock.lock()
            clientFD = client
            lock.unlock()

            if let code = Self.readAuthCode(from: client, expectedState: expectedState) {
                closeAll()
                return GoogleLoopback.Result(code: code, redirectURI: GoogleOAuth.loopbackRedirectURI)
            }
            lock.lock()
            if clientFD == client {
                _ = Darwin.close(client)
                clientFD = -1
            }
            lock.unlock()
        }
    }

    private static func readAuthCode(from client: Int32, expectedState: String) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let n = recv(client, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk.prefix(Int(n)))
            guard let raw = String(data: buffer, encoding: .utf8),
                  raw.contains("\r\n\r\n")
            else { continue }

            let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"
            let html: String
            let code: String?
            do {
                code = try GoogleOAuth.parseCallbackPath(path, expectedState: expectedState)
                html = """
                <html><body style="font-family:system-ui;padding:40px">
                <h2>GrizzyBot is signed in</h2>
                <p>You can close this tab and return to the app.</p>
                </body></html>
                """
            } catch {
                code = nil
                html = """
                <html><body style="font-family:system-ui;padding:40px">
                <h2>Sign-in failed</h2>
                <p>\(error.localizedDescription)</p>
                </body></html>
                """
            }
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            _ = response.withCString { ptr in
                Darwin.send(client, ptr, strlen(ptr), 0)
            }
            return code
        }
        return nil
    }
}
