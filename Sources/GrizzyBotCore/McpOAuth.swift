import CryptoKit
import Foundation
import Network
import Security

// MARK: - Tokens

public struct McpOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientId: String
    public var tokenEndpoint: String
    public var resource: String

    public func isFresh(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > skew
    }
}

enum McpOAuthKeychain {
    private static let service = "GrizzyBot.McpOAuth"

    static func load(_ key: String) -> McpOAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(McpOAuthTokens.self, from: data)
    }

    static func save(_ tokens: McpOAuthTokens, key: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}

// MARK: - Pure helpers

public enum McpOAuth {
    /// Opens the sign-in page. The app sets this to `NSWorkspace.shared.open`.
    nonisolated(unsafe) public static var openBrowser: (@Sendable (URL) -> Void)?
    public static let signInTimeout: TimeInterval = 300

    public static func serverKey(_ endpoint: URL) -> String {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        c?.query = nil; c?.fragment = nil
        return (c?.url ?? endpoint).absoluteString
    }

    public static func origin(_ url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.path = ""; c?.query = nil; c?.fragment = nil
        return c?.url
    }

    /// `resource_metadata` URL out of a `WWW-Authenticate: Bearer ...` header.
    public static func resourceMetadataURL(from header: String?) -> URL? {
        guard let header, let r = header.range(of: #"resource_metadata\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let part = String(header[r])
        guard let q1 = part.firstIndex(of: "\""), let q2 = part.lastIndex(of: "\""), q1 < q2 else { return nil }
        return URL(string: String(part[part.index(after: q1)..<q2]))
    }

    public static func randomURLSafe(bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func pkceChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func authorizationURL(
        endpoint: String, clientId: String, redirectURI: String,
        challenge: String, state: String, resource: String, scope: String?
    ) -> URL? {
        guard var c = URLComponents(string: endpoint) else { return nil }
        var items = c.queryItems ?? []
        items += [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource),
        ]
        if let scope, !scope.isEmpty { items.append(.init(name: "scope", value: scope)) }
        c.queryItems = items
        return c.url
    }

    public static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// Code and state from the callback request line (`GET /callback?code=..&state=.. HTTP/1.1`).
    public static func parseCallback(requestLine: String) -> (code: String?, state: String?, error: String?) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let c = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return (nil, nil, nil) }
        func v(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        return (v("code"), v("state"), v("error"))
    }

    static func tokens(fromResponse data: Data, clientId: String, tokenEndpoint: String, resource: String,
                       previousRefresh: String?, now: Date = Date()) throws -> McpOAuthTokens {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw McpError.transport("OAuth token response rejected\(detail.map { ": \($0)" } ?? "")")
        }
        let ttl = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init)
        return McpOAuthTokens(
            accessToken: access,
            refreshToken: (obj["refresh_token"] as? String) ?? previousRefresh,
            expiresAt: ttl.map { now.addingTimeInterval($0) },
            clientId: clientId, tokenEndpoint: tokenEndpoint, resource: resource
        )
    }
}

// MARK: - Loopback callback

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

final class McpOAuthCallbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var waiter: CheckedContinuation<(code: String?, state: String?, error: String?), Never>?
    private var result: (code: String?, state: String?, error: String?)?
    private(set) var port: UInt16 = 0

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener = l
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
        }
        port = l.port?.rawValue ?? 0
        guard port != 0 else { throw McpError.transport("Could not open a local sign-in callback port") }
    }

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    func wait(timeout: TimeInterval) async -> (code: String?, state: String?, error: String?) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish((nil, nil, "timed out waiting for sign-in"))
        }
        return await withCheckedContinuation { cont in
            lock.lock()
            if let r = result { lock.unlock(); cont.resume(returning: r); return }
            waiter = cont
            lock.unlock()
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func finish(_ r: (code: String?, state: String?, error: String?)) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parsed = McpOAuth.parseCallback(requestLine: line)
            let ok = parsed.code != nil && parsed.error == nil
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(ok ? "Signed in" : "Sign-in failed")</h2><p>You can close this tab and return to GrizzyBot.</p></body></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if parsed.code != nil || parsed.error != nil { self?.finish(parsed) }
        }
    }
}

// MARK: - Manager

public actor McpOAuthManager {
    public static let shared = McpOAuthManager()
    private var inFlight: [String: Task<McpOAuthTokens, Error>] = [:]

    /// A usable bearer token for this server, refreshing if it has expired. Nil if never signed in.
    public func currentToken(for endpoint: URL) async -> String? {
        let key = McpOAuth.serverKey(endpoint)
        guard let tokens = McpOAuthKeychain.load(key) else { return nil }
        if tokens.isFresh() { return tokens.accessToken }
        if let refreshed = try? await refresh(tokens, key: key) { return refreshed.accessToken }
        return nil
    }

    public func signOut(endpoint: URL) { McpOAuthKeychain.delete(McpOAuth.serverKey(endpoint)) }

    /// Runs the browser sign-in (single flight per server) and stores the tokens.
    public func authorize(endpoint: URL, wwwAuthenticate: String?) async throws {
        let key = McpOAuth.serverKey(endpoint)
        if let running = inFlight[key] { _ = try await running.value; return }
        let task = Task { try await Self.runFlow(endpoint: endpoint, wwwAuthenticate: wwwAuthenticate) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let tokens = try await task.value
        McpOAuthKeychain.save(tokens, key: key)
    }

    private func refresh(_ t: McpOAuthTokens, key: String) async throws -> McpOAuthTokens {
        guard let refresh = t.refreshToken, let url = URL(string: t.tokenEndpoint) else {
            McpOAuthKeychain.delete(key); throw McpError.transport("OAuth session expired")
        }
        let data = try await Self.post(url, form: [
            ("grant_type", "refresh_token"), ("refresh_token", refresh),
            ("client_id", t.clientId), ("resource", t.resource),
        ])
        do {
            let next = try McpOAuth.tokens(fromResponse: data, clientId: t.clientId, tokenEndpoint: t.tokenEndpoint,
                                           resource: t.resource, previousRefresh: refresh)
            McpOAuthKeychain.save(next, key: key)
            return next
        } catch {
            McpOAuthKeychain.delete(key)
            throw error
        }
    }

    // MARK: flow

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var r = URLRequest(url: url); r.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func post(_ url: URL, form: [(String, String)]) async throws -> Data {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"; r.timeoutInterval = 30
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = McpOAuth.formBody(form)
        let (d, _) = try await URLSession.shared.data(for: r)
        return d
    }

    private static func runFlow(endpoint: URL, wwwAuthenticate: String?) async throws -> McpOAuthTokens {
        guard let open = McpOAuth.openBrowser else {
            throw McpError.transport("This MCP server needs sign-in, but no browser is available here.")
        }
        guard let origin = McpOAuth.origin(endpoint) else { throw McpError.invalidConfiguration("Bad MCP URL") }
        let resource = McpOAuth.serverKey(endpoint)

        // 1. Which authorization server protects this resource?
        var authServer = origin
        let prmURL = McpOAuth.resourceMetadataURL(from: wwwAuthenticate)
            ?? origin.appendingPathComponent(".well-known/oauth-protected-resource")
        if let prm = await getJSON(prmURL), let first = (prm["authorization_servers"] as? [String])?.first,
           let u = URL(string: first) { authServer = u }

        // 2. Its endpoints.
        var meta: [String: Any]?
        for path in [".well-known/oauth-authorization-server", ".well-known/openid-configuration"] {
            let base = McpOAuth.origin(authServer) ?? authServer
            if let m = await getJSON(base.appendingPathComponent(path)) { meta = m; break }
        }
        guard let meta,
              let authEndpoint = meta["authorization_endpoint"] as? String,
              let tokenEndpoint = meta["token_endpoint"] as? String else {
            throw McpError.transport("Could not discover this server's OAuth endpoints.")
        }

        // 3. Loopback callback, then register a public client for its redirect URI.
        let callback = McpOAuthCallbackServer()
        try await callback.start()
        defer { callback.stop() }
        let redirect = callback.redirectURI
        guard let regString = meta["registration_endpoint"] as? String, let regURL = URL(string: regString) else {
            throw McpError.transport("This server does not support automatic client registration.")
        }
        var reg = URLRequest(url: regURL)
        reg.httpMethod = "POST"; reg.timeoutInterval = 30
        reg.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reg.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "GrizzyBot", "redirect_uris": [redirect],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (regData, _) = try await URLSession.shared.data(for: reg)
        guard let regObj = try? JSONSerialization.jsonObject(with: regData) as? [String: Any],
              let clientId = regObj["client_id"] as? String else {
            throw McpError.transport("OAuth client registration was rejected.")
        }

        // 4. Browser sign-in with PKCE.
        let verifier = McpOAuth.randomURLSafe(bytes: 48)
        let state = McpOAuth.randomURLSafe(bytes: 16)
        let scope = (meta["scopes_supported"] as? [String])?.joined(separator: " ")
        guard let url = McpOAuth.authorizationURL(
            endpoint: authEndpoint, clientId: clientId, redirectURI: redirect,
            challenge: McpOAuth.pkceChallenge(verifier: verifier), state: state, resource: resource, scope: scope
        ) else { throw McpError.transport("Bad authorization endpoint") }
        open(url)
        let got = await callback.wait(timeout: McpOAuth.signInTimeout)
        guard got.error == nil, let code = got.code else {
            throw McpError.transport("Sign-in did not finish: \(got.error ?? "no code returned")")
        }
        guard got.state == state else { throw McpError.transport("Sign-in state mismatch; try again.") }

        // 5. Exchange the code.
        guard let tokenURL = URL(string: tokenEndpoint) else { throw McpError.transport("Bad token endpoint") }
        let data = try await post(tokenURL, form: [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect),
            ("client_id", clientId), ("code_verifier", verifier), ("resource", resource),
        ])
        return try McpOAuth.tokens(fromResponse: data, clientId: clientId, tokenEndpoint: tokenEndpoint,
                                   resource: resource, previousRefresh: nil)
    }
}
