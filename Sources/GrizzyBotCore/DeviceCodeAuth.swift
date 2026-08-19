import Foundation

public struct OAuthCredential: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String
    public var expires: TimeInterval
    public var tokenType: String
    public var extra: [String: String]

    public init(
        access: String,
        refresh: String = "",
        expires: TimeInterval,
        tokenType: String = "Bearer",
        extra: [String: String] = [:]
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.tokenType = tokenType
        self.extra = extra
    }
}

public struct DeviceCodeSession: Sendable, Equatable {
    public var provider: String
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: String
    public var interval: TimeInterval
    public var expiresAt: Date
    public var clientId: String
    public var tokenURL: String

    public init(
        provider: String,
        deviceCode: String,
        userCode: String,
        verificationURI: String,
        interval: TimeInterval,
        expiresAt: Date,
        clientId: String,
        tokenURL: String
    ) {
        self.provider = provider
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.interval = interval
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.tokenURL = tokenURL
    }
}

public enum DeviceCodeError: Error, LocalizedError, Sendable, Equatable {
    case pending
    case denied
    case expired
    case http(Int, String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .pending: return "Waiting for you to approve the code in the browser."
        case .denied: return "Sign-in was denied."
        case .expired: return "The device code expired. Start again."
        case .http(let code, let body): return "OAuth failed (\(code)): \(body)"
        case .unsupported(let p): return "No device-code login for \(p)."
        }
    }
}

/// Real OAuth 2.0 device-code flows for ChatGPT/Codex, GitHub Copilot, and xAI.
public enum DeviceCodeAuth {
    public static let openaiClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let copilotClientId = "Iv1.b507a08c87ecfe98"
    public static let xaiClientId = "xai-grizzybot"

    public static func begin(provider: String) async throws -> DeviceCodeSession {
        switch provider {
        case "openai-codex", "openai":
            return try await beginForm(
                provider: provider,
                clientId: openaiClientId,
                codeURL: "https://auth.openai.com/oauth/device/code",
                tokenURL: "https://auth.openai.com/oauth/token",
                extra: ["scope": "openid profile email offline_access"]
            )
        case "github-copilot":
            return try await beginForm(
                provider: provider,
                clientId: copilotClientId,
                codeURL: "https://github.com/login/device/code",
                tokenURL: "https://github.com/login/oauth/access_token",
                extra: ["scope": "read:user"]
            )
        case "xai":
            return try await beginForm(
                provider: provider,
                clientId: xaiClientId,
                codeURL: "https://auth.x.ai/oauth/device/code",
                tokenURL: "https://auth.x.ai/oauth/token",
                extra: ["scope": "offline_access"]
            )
        default:
            throw DeviceCodeError.unsupported(provider)
        }
    }

    public static func poll(_ session: DeviceCodeSession) async throws -> OAuthCredential {
        if Date() > session.expiresAt { throw DeviceCodeError.expired }
        var parts = [
            "client_id=\(urlEncode(session.clientId))",
            "device_code=\(urlEncode(session.deviceCode))",
            "grant_type=\(urlEncode("urn:ietf:params:oauth:grant-type:device_code"))",
        ]
        if session.provider == "openai-codex" || session.provider == "openai" {
            parts.append("client_id=\(urlEncode(session.clientId))")
        }
        let body = parts.joined(separator: "&")
        var request = URLRequest(url: URL(string: session.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let error = (json["error"] as? String) ?? ""
        if error == "authorization_pending" || error == "slow_down" {
            throw DeviceCodeError.pending
        }
        if error == "access_denied" { throw DeviceCodeError.denied }
        if error == "expired_token" { throw DeviceCodeError.expired }
        if !(200..<300).contains(status), json["access_token"] == nil {
            throw DeviceCodeError.http(status, String(data: data, encoding: .utf8) ?? error)
        }
        var access = (json["access_token"] as? String) ?? ""
        let refresh = (json["refresh_token"] as? String) ?? ""
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        if session.provider == "github-copilot" {
            access = try await exchangeCopilotToken(githubToken: access)
        }
        guard !access.isEmpty else {
            throw DeviceCodeError.http(status, "missing access_token")
        }
        return OAuthCredential(
            access: access,
            refresh: refresh,
            expires: Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
            extra: ["provider": session.provider]
        )
    }

    public static func resolveAccessToken(
        apiKey: String?,
        oauthJSON: String?,
        provider: String
    ) async -> String? {
        if let json = oauthJSON, let data = json.data(using: .utf8),
           let cred = try? JSONDecoder().decode(OAuthCredential.self, from: data) {
            if cred.expires - Date().timeIntervalSince1970 > 60 {
                return cred.access
            }
            if !cred.refresh.isEmpty, let refreshed = try? await refresh(cred, provider: provider) {
                return refreshed.access
            }
            if !cred.access.isEmpty { return cred.access }
        }
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func refresh(_ credential: OAuthCredential, provider: String) async throws -> OAuthCredential {
        let tokenURL: String
        let clientId: String
        switch provider {
        case "openai-codex", "openai":
            tokenURL = "https://auth.openai.com/oauth/token"
            clientId = openaiClientId
        case "github-copilot":
            tokenURL = "https://github.com/login/oauth/access_token"
            clientId = copilotClientId
        case "xai":
            tokenURL = "https://auth.x.ai/oauth/token"
            clientId = xaiClientId
        default:
            return credential
        }
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            "grant_type=refresh_token&refresh_token=\(urlEncode(credential.refresh))&client_id=\(urlEncode(clientId))"
                .utf8
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            return credential
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return OAuthCredential(
            access: access,
            refresh: (json["refresh_token"] as? String) ?? credential.refresh,
            expires: Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
            extra: credential.extra
        )
    }

    private static func beginForm(
        provider: String,
        clientId: String,
        codeURL: String,
        tokenURL: String,
        extra: [String: String]
    ) async throws -> DeviceCodeSession {
        var pairs = ["client_id=\(urlEncode(clientId))"]
        for (key, value) in extra {
            pairs.append("\(urlEncode(key))=\(urlEncode(value))")
        }
        var request = URLRequest(url: URL(string: codeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(pairs.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            throw DeviceCodeError.http(status, String(data: data, encoding: .utf8) ?? "no device_code")
        }
        let uri = (json["verification_uri"] as? String)
            ?? (json["verification_uri_complete"] as? String)
            ?? ModelCatalog.verificationURI(forProvider: provider)
        let interval = (json["interval"] as? Double) ?? 5
        let expiresIn = (json["expires_in"] as? Double) ?? 900
        return DeviceCodeSession(
            provider: provider,
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            interval: interval,
            expiresAt: Date().addingTimeInterval(expiresIn),
            clientId: clientId,
            tokenURL: tokenURL
        )
    }

    private static func exchangeCopilotToken(githubToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/v2/token")!)
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let token = json["token"] as? String, !token.isEmpty {
            return token
        }
        if (200..<300).contains(status) { return githubToken }
        throw DeviceCodeError.http(status, String(data: data, encoding: .utf8) ?? "copilot token failed")
    }

    private static func urlEncode(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
    }
}
