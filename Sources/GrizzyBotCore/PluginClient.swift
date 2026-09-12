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
    /// Removes one record. Defaulted so a connector without a delete API says
    /// so rather than every conformer having to.
    func delete(slug: String, token: String, id: String) async throws -> String
}

extension PluginConnecting {
    public func delete(slug: String, token: String, id: String) async throws -> String {
        throw PluginError.rejected("\(slug) has no delete API in GrizzyBot — nothing was removed.")
    }
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
        case "gmail", "google-calendar", "google-sheets", "google-docs", "google-drive", "googledrive", "gdrive":
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
        case "gmail":
            // The tool has always advertised "action=write sends mail"; until
            // now it fell through to a branch that sent nothing.
            let draft = try GmailDraft.parse(title: title, body: body)
            let json = try await postJSON(
                "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
                token: token,
                body: ["raw": draft.rawMessage()]
            )
            guard let id = json["id"] as? String else {
                throw PluginError.rejected("Gmail returned no message id, so nothing was sent.")
            }
            return "sent to \(draft.to.joined(separator: ", ")) (\(id))"

        case "google-sheets", "googlesheets":
            let ref = try SheetsRef.parse(body.isEmpty ? title : body)
            let rows = SheetsRef.rows(from: body)
            guard !rows.isEmpty else {
                throw PluginError.rejected("No rows to append. Pass values as JSON, TSV, or CSV in the body.")
            }
            let json = try await postJSON(
                "https://sheets.googleapis.com/v4/spreadsheets/\(urlEncode(ref.spreadsheetId))/values/\(urlEncode(ref.range)):append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS",
                token: token,
                body: ["values": rows]
            )
            let updates = json["updates"] as? [String: Any]
            let cells = (updates?["updatedCells"] as? NSNumber)?.intValue ?? 0
            return "appended \(rows.count) row\(rows.count == 1 ? "" : "s") (\(cells) cells) to \(ref.spreadsheetId)"

        case "google-docs", "googledocs":
            let (fields, remainder) = GoogleRequests.fields(body)
            let text = fields["body"] ?? fields["text"] ?? fields["content"] ?? remainder
            let created = try await postJSON(
                "https://docs.googleapis.com/v1/documents",
                token: token,
                body: ["title": title.isEmpty ? "Untitled" : title]
            )
            guard let documentId = created["documentId"] as? String else {
                throw PluginError.rejected("Docs returned no documentId, so nothing was created.")
            }
            if !text.isEmpty {
                _ = try await postJSON(
                    "https://docs.googleapis.com/v1/documents/\(urlEncode(documentId)):batchUpdate",
                    token: token,
                    body: ["requests": [["insertText": ["location": ["index": 1], "text": text]]]]
                )
            }
            return "https://docs.google.com/document/d/\(documentId)/edit"

        case "google-drive", "googledrive", "gdrive":
            let (fields, remainder) = GoogleRequests.fields(body)
            let name = [fields["name"], fields["filename"], title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "untitled.txt"
            let content = fields["body"] ?? fields["text"] ?? fields["content"] ?? remainder
            guard !content.isEmpty else {
                throw PluginError.rejected("Nothing to upload — the body is empty.")
            }
            let json = try await postMultipart(
                "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink",
                token: token,
                body: DriveUpload.multipart(
                    name: name,
                    mimeType: fields["mimetype"] ?? fields["mime_type"] ?? DriveUpload.mimeType(for: name),
                    content: content,
                    folderId: fields["parent"] ?? fields["folderid"] ?? fields["folder_id"]
                )
            )
            return (json["webViewLink"] as? String) ?? (json["id"] as? String) ?? name

        case "google-calendar", "googlecalendar":
            let draft = try CalendarEventDraft.parse(title: title, body: body)
            let json = try await postJSON(
                "https://www.googleapis.com/calendar/v3/calendars/\(urlEncode(draft.calendarId))/events",
                token: token,
                body: draft.googleBody()
            )
            guard let id = json["id"] as? String else {
                throw PluginError.rejected("Google returned no event id, so the event was not created.")
            }
            // Return the link, not a bare "ok" — the caller quotes this back as
            // proof, and a real Google id is the only honest proof there is.
            return (json["htmlLink"] as? String) ?? id
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
            // Never report success for a slug with no write API: a fabricated
            // "wrote local" sends the caller hunting for a sync bug that does
            // not exist. Mirror search's default and say nothing was sent.
            throw PluginError.rejected(
                "\(slug) has no write API in GrizzyBot — nothing was sent. Connect Composio for \(slug) writes."
            )
        }
    }

    public func delete(slug: String, token: String, id: String) async throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError.rejected("An id is required to delete. Read the calendar first — each result ends with [eventId].")
        }
        switch slug {
        case "google-calendar", "googlecalendar":
            // Accept a bare id, or the JSON the model tends to produce.
            var eventId = trimmed
            var calendarId = "primary"
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                eventId = (object["eventId"] as? String)
                    ?? (object["event_id"] as? String)
                    ?? (object["id"] as? String)
                    ?? ""
                calendarId = (object["calendarId"] as? String)
                    ?? (object["calendar_id"] as? String)
                    ?? "primary"
            }
            guard !eventId.isEmpty else {
                throw PluginError.rejected("No eventId in \(trimmed). Read the calendar first — each result ends with [eventId].")
            }
            try await deleteRequest(
                "https://www.googleapis.com/calendar/v3/calendars/\(urlEncode(calendarId))/events/\(urlEncode(eventId))",
                token: token
            )
            return eventId
        default:
            throw PluginError.rejected("\(slug) has no delete API in GrizzyBot — nothing was removed.")
        }
    }

    public func search(slug: String, token: String, query: String) async throws -> String {
        let q = ComposioClient.normalizedReadQuery(slug: slug, query: query)
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
        case "gmail":
            let encoded = urlEncode(q)
            let json = try await getJSON(
                "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=\(encoded)&maxResults=8",
                token: token
            )
            let messages = (json["messages"] as? [[String: Any]]) ?? []
            if messages.isEmpty { return "No Gmail messages for \(q)." }
            var lines: [String] = []
            for message in messages.prefix(8) {
                guard let id = message["id"] as? String else { continue }
                let detail = try await getJSON(
                    "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=Subject&metadataHeaders=From",
                    token: token
                )
                let headers = ((detail["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
                func header(_ name: String) -> String {
                    headers.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() })?["value"] as? String ?? ""
                }
                let subject = header("Subject")
                let from = header("From")
                lines.append("• \(subject.isEmpty ? id : subject) — \(from)")
            }
            return lines.joined(separator: "\n")
        case "google-calendar", "googlecalendar":
            var request = CalendarReadQueryParser.parse(q)
            // A calendar named rather than identified ("Ed Griswold") is not a
            // usable id. Resolve it against the account's calendar list instead
            // of searching for the words, which is what used to happen.
            if request.calendarId != "primary", !request.calendarId.contains("@") {
                request.calendarId = try await resolveCalendarId(request.calendarId, token: token)
            }
            let json = try await getJSON(request.url(), token: token)
            let items = (json["items"] as? [[String: Any]]) ?? []
            if items.isEmpty {
                return "No Calendar events for \(request.describedAs)."
            }
            return items.prefix(request.maxResults).map { item in
                let summary = item["summary"] as? String ?? "(no title)"
                let start = ((item["start"] as? [String: Any])?["dateTime"] as? String)
                    ?? ((item["start"] as? [String: Any])?["date"] as? String)
                    ?? ""
                // The id travels with the result so a follow-up can act on the
                // event without a second lookup.
                let id = (item["id"] as? String).map { " [\($0)]" } ?? ""
                return "• \(summary) — \(start)\(id)"
            }.joined(separator: "\n")
        case "google-sheets", "googlesheets":
            let ref = try SheetsRef.parse(q)
            let json = try await getJSON(
                "https://sheets.googleapis.com/v4/spreadsheets/\(urlEncode(ref.spreadsheetId))/values/\(urlEncode(ref.range))",
                token: token
            )
            let values = (json["values"] as? [[Any]]) ?? []
            if values.isEmpty { return "No rows in \(ref.range) of \(ref.spreadsheetId)." }
            return values.prefix(50).map { row in
                "• " + row.map { cell in (cell as? String) ?? String(describing: cell) }.joined(separator: " | ")
            }.joined(separator: "\n")
        case "google-docs", "googledocs":
            let encoded = urlEncode("mimeType='application/vnd.google-apps.document' \(q)")
            let json = try await getJSON(
                "https://www.googleapis.com/drive/v3/files?q=\(encoded)&pageSize=8&fields=files(id,name)",
                token: token
            )
            let files = (json["files"] as? [[String: Any]]) ?? []
            if files.isEmpty { return "No Google Docs for \(q)." }
            return files.prefix(8).compactMap { item in
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
            throw PluginError.rejected("Paste-token \(slug) has no read API in GrizzyBot. Connect Composio or Google OAuth for search.")
        }
    }

    /// Maps a calendar's display name to its id via the account's calendar
    /// list. Falls back to the given string so an id that simply is not in the
    /// list still reaches Google and produces a real error.
    private func resolveCalendarId(_ name: String, token: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "primary" }
        let json = try await getJSON(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=250",
            token: token
        )
        let items = (json["items"] as? [[String: Any]]) ?? []
        for item in items {
            let summary = (item["summary"] as? String) ?? ""
            let id = (item["id"] as? String) ?? ""
            if summary.compare(trimmed, options: .caseInsensitive) == .orderedSame { return id }
            if id.compare(trimmed, options: .caseInsensitive) == .orderedSame { return id }
        }
        if items.contains(where: { ($0["primary"] as? Bool) == true }) {
            // Named something that is not a calendar here — say so by listing
            // what does exist rather than silently reading the wrong one.
            let names = items.compactMap { $0["summary"] as? String }.prefix(10).joined(separator: ", ")
            throw PluginError.rejected("No calendar named \(trimmed). Available: \(names).")
        }
        return trimmed
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
        case "gmail", "google-calendar", "google-sheets", "google-docs", "google-drive":
            return "Google OAuth access token — or use Client ID/Secret in Settings → Google"
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

    /// Human-readable failure for a REST API error body.
    ///
    /// Google pretty-prints its error JSON, so the first line is just `{` — never truncate to it.
    /// 401 means the token expired; 403 usually means the API is disabled for the Cloud project
    /// or the grant is missing a scope. Those need opposite fixes, so they must not share a hint.
    static func apiErrorMessage(status: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]

        let message = (error?["message"] as? String)
            ?? (json?["error_description"] as? String)
            ?? (json?["error"] as? String)
            ?? collapseWhitespace(text)

        var reasons: [String] = []
        if let status = error?["status"] as? String { reasons.append(status) }
        for entry in (error?["errors"] as? [[String: Any]]) ?? [] {
            if let reason = entry["reason"] as? String { reasons.append(reason) }
        }
        for entry in (error?["details"] as? [[String: Any]]) ?? [] {
            if let reason = entry["reason"] as? String { reasons.append(reason) }
        }
        let matches: (String) -> Bool = { needle in
            reasons.contains { $0.caseInsensitiveCompare(needle) == .orderedSame }
        }
        let says: (String) -> Bool = { needle in
            message.localizedCaseInsensitiveContains(needle)
        }

        let hint: String
        switch status {
        case 401:
            hint = "Google sign-in expired — reconnect from Plugins (Sign in with Google)."
        case 403 where matches("accessNotConfigured")
            || says("has not been used in project")
            || says("is disabled"):
            let enable = firstURL(in: message).map { " Enable it here: \($0)" } ?? ""
            hint = "That API is not enabled for your Google Cloud project."
                + enable
                + " Enable it, wait ~30s, then retry — you do not need to sign in again."
        case 403 where matches("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || matches("insufficientPermission"):
            hint = "This sign-in is missing a required scope — reconnect from Plugins (Sign in with Google) to re-consent."
        case 403 where matches("rateLimitExceeded") || matches("userRateLimitExceeded"), 429:
            hint = "Rate limited by Google — wait a moment and retry."
        case 403:
            hint = "Access denied by Google."
        default:
            hint = ""
        }

        let detail = collapseWhitespace(message)
        return "HTTP \(status)"
            + (hint.isEmpty ? "" : " \(hint)")
            + (detail.isEmpty ? "" : ": \(String(detail.prefix(300)))")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>(),.;"))
            if trimmed.hasPrefix("https://") { return trimmed }
        }
        return nil
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
            throw PluginError.rejected(Self.apiErrorMessage(status: status, body: data))
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
            throw PluginError.rejected(Self.apiErrorMessage(status: status, body: data))
        }
        return json
    }

    private func deleteRequest(_ url: String, token: String) async throws {
        guard let parsed = URL(string: url) else { throw PluginError.rejected("bad url") }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Google answers a successful delete with 204, and 410 when the event
        // is already gone — which is the outcome the caller wanted either way.
        guard (200..<300).contains(status) || status == 410 else {
            throw PluginError.rejected(Self.apiErrorMessage(status: status, body: data))
        }
    }

    private func postMultipart(_ url: String, token: String, body: Data) async throws -> [String: Any] {
        guard let parsed = URL(string: url) else { throw PluginError.rejected("bad url") }
        var request = URLRequest(url: parsed, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(DriveUpload.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginError.rejected(Self.apiErrorMessage(status: status, body: data))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
