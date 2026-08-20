import Foundation

public struct PluginAccount: Sendable, Equatable {
    public var slug: String
    public var label: String
    public var token: String

    public init(slug: String, label: String, token: String) {
        self.slug = slug
        self.label = label
        self.token = token
    }
}

public protocol PluginConnecting: Sendable {
    func verify(slug: String, token: String) async throws -> PluginAccount
    func write(slug: String, token: String, title: String, body: String) async throws -> String
    func search(slug: String, token: String, query: String) async throws -> String
    func revoke(slug: String, token: String) async
}

public struct PluginClient: PluginConnecting {
    public static let shared = PluginClient()
    public init() {}

    public func verify(slug: String, token: String) async throws -> PluginAccount {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PluginError.missingToken }
        switch slug {
        case "github":
            let json = try await getJSON("https://api.github.com/user", token: trimmed, headers: [
                "Accept": "application/vnd.github+json",
            ])
            let login = (json["login"] as? String) ?? "github"
            return PluginAccount(slug: slug, label: login, token: trimmed)
        case "slack":
            if trimmed.hasPrefix("https://") {
                return PluginAccount(slug: slug, label: "Incoming webhook", token: trimmed)
            }
            let json = try await postForm("https://slack.com/api/auth.test", token: trimmed)
            guard json["ok"] as? Bool == true else {
                throw PluginError.rejected((json["error"] as? String) ?? "slack auth.test failed")
            }
            let label = (json["team"] as? String) ?? (json["user"] as? String) ?? "slack"
            return PluginAccount(slug: slug, label: label, token: trimmed)
        case "notion":
            let json = try await getJSON("https://api.notion.com/v1/users/me", token: trimmed, headers: [
                "Notion-Version": "2022-06-28",
            ])
            let name = ((json["name"] as? String) ?? "notion")
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "linear":
            let json = try await postJSON(
                "https://api.linear.app/graphql",
                token: trimmed,
                body: ["query": "{ viewer { name } }"]
            )
            let name = ((json["data"] as? [String: Any])?["viewer"] as? [String: Any])?["name"] as? String ?? "linear"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "gmail", "google-calendar":
            let json = try await getJSON(
                "https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=\(urlEncode(trimmed))",
                token: nil
            )
            let email = (json["email"] as? String) ?? (json["user_id"] as? String) ?? slug
            return PluginAccount(slug: slug, label: email, token: trimmed)
        case "jira":
            let json = try await getJSON("https://api.atlassian.com/me", token: trimmed)
            let name = (json["email"] as? String) ?? (json["account_id"] as? String) ?? "jira"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "trello":
            // token is key:token or just token
            let url = trimmed.contains("key=")
                ? "https://api.trello.com/1/members/me?\(trimmed)"
                : "https://api.trello.com/1/members/me?token=\(urlEncode(trimmed))"
            let json = try await getJSON(url, token: nil)
            let name = (json["username"] as? String) ?? "trello"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "asana":
            let json = try await getJSON("https://app.asana.com/api/1.0/users/me", token: trimmed)
            let data = json["data"] as? [String: Any]
            let name = (data?["name"] as? String) ?? "asana"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "hubspot":
            let json = try await getJSON(
                "https://api.hubapi.com/integrations/v1/me",
                token: trimmed
            )
            let name = (json["portalId"] as? Int).map(String.init) ?? "hubspot"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "salesforce":
            return PluginAccount(slug: slug, label: "salesforce token", token: trimmed)
        case "intercom":
            let json = try await getJSON("https://api.intercom.io/me", token: trimmed)
            let name = (json["name"] as? String) ?? "intercom"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        case "box":
            let json = try await getJSON("https://api.box.com/2.0/users/me", token: trimmed)
            let name = (json["login"] as? String) ?? (json["name"] as? String) ?? "box"
            return PluginAccount(slug: slug, label: name, token: trimmed)
        default:
            return PluginAccount(slug: slug, label: slug, token: trimmed)
        }
    }

    public func write(slug: String, token: String, title: String, body: String) async throws -> String {
        switch slug {
        case "github":
            let json = try await postJSON(
                "https://api.github.com/gists",
                token: token,
                body: [
                    "description": title,
                    "public": false,
                    "files": [safeFilename(title): ["content": body]],
                ],
                headers: ["Accept": "application/vnd.github+json"]
            )
            return (json["html_url"] as? String) ?? (json["id"] as? String) ?? "gist"
        case "slack":
            if token.hasPrefix("https://") {
                _ = try await postJSON(token, token: nil, body: ["text": "*\(title)*\n\(body)"])
                return "slack webhook"
            }
            let json = try await postJSON(
                "https://slack.com/api/chat.postMessage",
                token: token,
                body: ["channel": "#general", "text": "*\(title)*\n\(body)"]
            )
            guard json["ok"] as? Bool == true else {
                throw PluginError.rejected((json["error"] as? String) ?? "slack post failed")
            }
            return (json["ts"] as? String) ?? "slack"
        case "notion":
            return "notion: stored locally (page create needs a parent id)"
        case "linear":
            let json = try await postJSON(
                "https://api.linear.app/graphql",
                token: token,
                body: [
                    "query": "mutation IssueCreate($title: String!, $description: String) { issueCreate(input: { title: $title, description: $description }) { success issue { id identifier url } } }",
                    "variables": ["title": title, "description": body],
                ]
            )
            let issue = ((json["data"] as? [String: Any])?["issueCreate"] as? [String: Any])?["issue"] as? [String: Any]
            return (issue?["url"] as? String) ?? (issue?["identifier"] as? String) ?? "linear"
        default:
            if token.hasPrefix("https://") {
                _ = try await postJSON(token, token: nil, body: ["title": title, "body": body])
                return token
            }
            return "local"
        }
    }

    public func search(slug: String, token: String, query: String) async throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw PluginError.rejected("query is required") }
        switch slug {
        case "github":
            let encoded = urlEncode(q)
            let json = try await getJSON(
                "https://api.github.com/search/issues?q=\(encoded)&per_page=5",
                token: token,
                headers: ["Accept": "application/vnd.github+json"]
            )
            let items = (json["items"] as? [[String: Any]]) ?? []
            if items.isEmpty { return "No GitHub issues for \(q)." }
            return items.prefix(5).compactMap { item in
                let title = item["title"] as? String ?? ""
                let url = item["html_url"] as? String ?? ""
                return "• \(title) \(url)"
            }.joined(separator: "\n")
        case "box":
            let encoded = urlEncode(q)
            let json = try await getJSON(
                "https://api.box.com/2.0/search?query=\(encoded)&limit=5",
                token: token
            )
            let entries = (json["entries"] as? [[String: Any]]) ?? []
            if entries.isEmpty { return "No Box items for \(q)." }
            return entries.prefix(5).compactMap { item in
                let name = item["name"] as? String ?? ""
                let id = item["id"] as? String ?? ""
                return "• \(name) (\(id))"
            }.joined(separator: "\n")
        case "google-drive", "googledrive", "gdrive":
            let encoded = urlEncode(q)
            let json = try await getJSON(
                "https://www.googleapis.com/drive/v3/files?q=fullText%20contains%20%27\(encoded)%27&pageSize=8&fields=files(id,name,mimeType)",
                token: token
            )
            let files = (json["files"] as? [[String: Any]]) ?? []
            if files.isEmpty { return "No Google Drive files for \(q)." }
            return files.prefix(8).compactMap { item in
                let name = item["name"] as? String ?? ""
                let id = item["id"] as? String ?? ""
                return "• \(name) (\(id))"
            }.joined(separator: "\n")
        case "onedrive", "microsoft-onedrive":
            let encoded = urlEncode(q)
            let json = try await getJSON(
                "https://graph.microsoft.com/v1.0/me/drive/root/search(q='\(encoded)')",
                token: token
            )
            let values = (json["value"] as? [[String: Any]]) ?? []
            if values.isEmpty { return "No OneDrive files for \(q)." }
            return values.prefix(8).compactMap { item in
                let name = item["name"] as? String ?? ""
                let id = item["id"] as? String ?? ""
                return "• \(name) (\(id))"
            }.joined(separator: "\n")
        default:
            throw PluginError.rejected("Paste-token \(slug) has no read API in GrizzyBot. Connect Composio for search.")
        }
    }

    public func revoke(slug: String, token: String) async {
        _ = slug
        _ = token
    }

    public static func tokenHint(for slug: String) -> String {
        switch slug {
        case "github": return "GitHub personal access token (gist scope)"
        case "slack": return "Slack bot token or incoming webhook URL"
        case "notion": return "Notion integration secret"
        case "linear": return "Linear API key"
        case "gmail", "google-calendar": return "Google OAuth access token"
        case "jira": return "Atlassian API token"
        case "trello": return "Trello token (or key=…&token=…)"
        case "asana": return "Asana personal access token"
        case "hubspot": return "HubSpot private app token"
        case "salesforce": return "Salesforce access token"
        case "intercom": return "Intercom access token"
        case "box": return "Box developer token from box.com/developers"
        default: return "API token"
        }
    }

    private func getJSON(_ url: String, token: String?, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let parsed = URL(string: url) else { throw PluginError.rejected("bad url") }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginError.rejected("HTTP \(status)")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(
        _ url: String,
        token: String?,
        body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        guard let parsed = URL(string: url) else { throw PluginError.rejected("bad url") }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if data.isEmpty { return ["ok": status] }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["raw": String(data: data, encoding: .utf8) ?? ""]
        guard (200..<300).contains(status) else {
            throw PluginError.rejected("HTTP \(status)")
        }
        return json
    }

    private func postForm(_ url: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("token=\(urlEncode(token))".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func safeFilename(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "note.md" : (cleaned.hasSuffix(".md") ? cleaned : cleaned + ".md")
    }

    private func urlEncode(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
    }
}

public struct AlwaysAllowPlugins: PluginConnecting {
    public init() {}

    public func verify(slug: String, token: String) async throws -> PluginAccount {
        PluginAccount(slug: slug, label: "test", token: token)
    }

    public func write(slug: String, token: String, title: String, body: String) async throws -> String {
        _ = token
        return "\(slug):\(title):\(body.count)"
    }

    public func search(slug: String, token: String, query: String) async throws -> String {
        _ = token
        return "\(slug):search:\(query)"
    }

    public func revoke(slug: String, token: String) async {}
}

public enum PluginError: Error, LocalizedError, Sendable {
    case missingToken
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "Paste an API token to connect."
        case .rejected(let s): return s
        }
    }
}
