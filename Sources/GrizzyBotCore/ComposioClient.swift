import Foundation

public protocol ComposioConnecting: Sendable {
    func authorizeURL(for slug: String) async throws -> URL
    func isConnected(_ slug: String) async throws -> Bool
    func disconnect(_ slug: String) async throws
    func execute(slug: String, title: String, body: String, account: String?) async throws -> String
    func search(slug: String, query: String, account: String?) async throws -> String
    func listCatalog(query: String) async throws -> [ConnectionItem]
    /// Connected account aliases for a toolkit (empty when only one / unknown).
    func listAccounts(slug: String) async throws -> [String]
}

extension ComposioConnecting {
    public func execute(slug: String, title: String, body: String) async throws -> String {
        try await execute(slug: slug, title: title, body: body, account: nil)
    }

    public func search(slug: String, query: String) async throws -> String {
        try await search(slug: slug, query: query, account: nil)
    }

    public func listAccounts(slug: String) async throws -> [String] {
        []
    }
}

/// Composio Connect (same path OpenMausBot / rakazo use): browser OAuth, then tools.
public struct ComposioClient: ComposioConnecting, Sendable {
    public var connectKey: String
    public var apiKey: String?
    public var connectURL: String
    public var backendURL: String

    public static let defaultConnectURL = "https://connect.composio.dev/mcp"
    public static let defaultBackendURL = "https://backend.composio.dev/api/v3"
    public static let composioTokenSentinel = "composio"

    public init(
        connectKey: String,
        apiKey: String? = nil,
        connectURL: String = ComposioClient.defaultConnectURL,
        backendURL: String = ComposioClient.defaultBackendURL
    ) {
        self.connectKey = connectKey
        self.apiKey = apiKey
        self.connectURL = connectURL
        self.backendURL = backendURL
    }

    public static func toolkitSlug(_ slug: String) -> String {
        slug.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    /// Current Composio Connect MCP expects `toolkits: ["gmail", …]` (string slugs).
    public static func manageConnectionsArgs(
        toolkits: [String],
        reinitiateAll: Bool = false,
        sessionId: String? = nil
    ) -> [String: Any] {
        var args: [String: Any] = [
            "toolkits": toolkits.map { toolkitSlug($0) },
        ]
        if reinitiateAll { args["reinitiate_all"] = true }
        if let sessionId, !sessionId.isEmpty { args["session_id"] = sessionId }
        return args
    }

    public func authorizeURL(for slug: String) async throws -> URL {
        let toolkit = Self.toolkitSlug(slug)
        let out = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: Self.manageConnectionsArgs(toolkits: [toolkit])
        )
        if Self.connected(in: out, toolkit: toolkit) {
            throw PluginError.rejected("Composio already connected for \(slug).")
        }
        if let url = Self.firstAuthURL(in: out) { return url }
        let retry = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: Self.manageConnectionsArgs(toolkits: [toolkit], reinitiateAll: true)
        )
        if Self.connected(in: retry, toolkit: toolkit) {
            throw PluginError.rejected("Composio already connected for \(slug).")
        }
        if let url = Self.firstAuthURL(in: retry) { return url }
        throw PluginError.rejected("Composio returned no sign-in link for \(slug).")
    }

    public func isConnected(_ slug: String) async throws -> Bool {
        let toolkit = Self.toolkitSlug(slug)
        let out = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: Self.manageConnectionsArgs(toolkits: [toolkit])
        )
        return Self.connected(in: out, toolkit: toolkit)
    }

    public func disconnect(_ slug: String) async throws {
        let toolkit = Self.toolkitSlug(slug)
        let listed = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: Self.manageConnectionsArgs(toolkits: [toolkit])
        )
        let ids = Self.accountIds(in: listed, toolkit: toolkit)
        for id in ids {
            try await deleteConnectedAccount(id: id)
        }
    }

    private func deleteConnectedAccount(id: String) async throws {
        let key = (apiKey?.isEmpty == false ? apiKey : connectKey) ?? connectKey
        guard let url = URL(string: "\(backendURL)/connected_accounts/\(id)") else {
            throw PluginError.rejected("bad Composio account URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else {
            throw PluginError.rejected("Composio disconnect HTTP \(status)")
        }
    }

    public func execute(slug: String, title: String, body: String, account: String? = nil) async throws -> String {
        let toolkit = Self.toolkitSlug(slug)
        let query = [title, body].filter { !$0.isEmpty }.joined(separator: " ")
        let search = try await call(
            "COMPOSIO_SEARCH_TOOLS",
            arguments: [
                "queries": [query.isEmpty ? toolkit : query],
                "toolkits": [toolkit],
            ]
        )
        let tools = Self.toolSlugs(in: search)
        guard let tool = tools.first else {
            throw PluginError.rejected("No Composio tool found for \(slug).")
        }
        return try await executeTool(
            tool: tool,
            arguments: [
                "title": title,
                "body": body,
                "text": body,
                "content": body,
                "message": body,
                "subject": title,
            ],
            account: account,
            autoPickAccount: account == nil,
            fallbackLabel: "\(slug) via Composio (\(tool))"
        )
    }

    public func search(slug: String, query: String, account: String? = nil) async throws -> String {
        let toolkit = Self.toolkitSlug(slug)
        let q = Self.normalizedReadQuery(slug: slug, query: query)
        let search = try await call(
            "COMPOSIO_SEARCH_TOOLS",
            arguments: [
                "queries": [
                    toolkit == "gmail"
                        ? "list fetch emails inbox \(q)"
                        : (q.isEmpty ? "list \(toolkit)" : q),
                ],
                "toolkits": [toolkit],
            ]
        )
        let tools = Self.toolSlugs(in: search)
        guard let readTool = Self.preferredReadTool(in: tools, toolkit: toolkit) else {
            throw PluginError.rejected("No Composio read tool found for \(slug).")
        }
        return try await executeTool(
            tool: readTool,
            arguments: Self.readArguments(for: readTool, query: q),
            account: account,
            autoPickAccount: account == nil,
            fallbackLabel: "\(slug) search via \(readTool)"
        )
    }

    public func listAccounts(slug: String) async throws -> [String] {
        let toolkit = Self.toolkitSlug(slug)
        let search = try await call(
            "COMPOSIO_SEARCH_TOOLS",
            arguments: [
                "queries": ["list \(toolkit)"],
                "toolkits": [toolkit],
            ]
        )
        let tools = Self.toolSlugs(in: search)
        guard let tool = tools.first else { return [] }
        let toolPayload: [String: Any] = [
            "tool_slug": tool,
            "arguments": [
                "query": Self.normalizedReadQuery(slug: slug, query: ""),
            ],
        ]
        let executed = try await call(
            "COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: ["tools": [toolPayload]]
        )
        if let accounts = Self.multipleAccountChoices(in: executed) {
            return accounts
        }
        return []
    }

    private func executeTool(
        tool: String,
        arguments: [String: Any],
        account: String?,
        autoPickAccount: Bool,
        fallbackLabel: String
    ) async throws -> String {
        var toolPayload: [String: Any] = [
            "tool_slug": tool,
            "arguments": arguments,
        ]
        if let account, !account.isEmpty, account != "*" {
            toolPayload["account"] = account
            var args = arguments
            args["account"] = account
            toolPayload["arguments"] = args
        }
        let executed = try await call(
            "COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: ["tools": [toolPayload]]
        )
        if let accounts = Self.multipleAccountChoices(in: executed) {
            if autoPickAccount, let pick = Self.resolveAccountChoice(requested: account, available: accounts) {
                return try await executeTool(
                    tool: tool,
                    arguments: arguments,
                    account: pick,
                    autoPickAccount: false,
                    fallbackLabel: fallbackLabel
                )
            }
            throw PluginError.rejected(
                "Multiple accounts connected. Choose one in Plugins, or pass account: \(accounts.joined(separator: ", "))"
            )
        }
        if Self.isFailedExecution(executed) {
            throw PluginError.rejected(Self.shortFailure(executed, tool: tool))
        }
        let formatted = Self.formatToolResult(executed, tool: tool)
        if formatted.isEmpty { return fallbackLabel }
        return String(formatted.prefix(4_000))
    }

    /// Prefer inbox/list/search tools; avoid attachments, by-id, and Composio meta helpers.
    public static func preferredReadTool(in tools: [String], toolkit: String) -> String? {
        let scored = tools.map { tool -> (String, Int) in
            (tool, readToolScore(tool, toolkit: toolkit))
        }
        .filter { $0.1 > 0 }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return scored.first?.0 ?? tools.first
    }

    public static func readToolScore(_ tool: String, toolkit: String) -> Int {
        let u = tool.uppercased()
        if u.hasPrefix("COMPOSIO_") { return -100 }
        if u.contains("ATTACHMENT") || u.contains("SCHEMA") || u.contains("UPLOAD") {
            return -80
        }
        if u.contains("SEND") || u.contains("CREATE") || u.contains("DELETE")
            || u.contains("UPDATE") || u.contains("REPLY") || u.contains("DRAFT")
            || u.contains("MOVE") || u.contains("LABEL") || u.contains("TRASH")
        {
            return -60
        }
        if u.contains("BY_THREAD") || u.contains("BY_ID") || u.contains("BY_MESSAGE")
            || u.contains("MESSAGE_BY") || u.contains("THREAD_ID")
        {
            return -40
        }

        var score = 1
        if u.contains("FETCH_EMAILS") || u.contains("LIST_EMAIL") || u.contains("LIST_MESSAGES")
            || u.contains("FETCH_MESSAGES") || u.contains("GET_EMAILS")
        {
            score += 100
        }
        if u.contains("LIST") { score += 50 }
        if u.contains("SEARCH") { score += 45 }
        if u.contains("FETCH") { score += 35 }
        if u.contains("FIND") || u.contains("READ") { score += 25 }
        if u.contains("GET") { score += 8 }
        let tk = toolkit.uppercased()
        if !tk.isEmpty, u.hasPrefix(tk) || u.hasPrefix(tk.replacingOccurrences(of: "GOOGLE", with: "GOOGLE_")) {
            score += 5
        }
        return score
    }

    public static func readArguments(for tool: String, query: String) -> [String: Any] {
        let u = tool.uppercased()
        if u.contains("GMAIL") {
            return [
                "query": query,
                "q": query,
                "max_results": 10,
                "maxResults": 10,
                "label_ids": ["INBOX"],
            ]
        }
        return [
            "query": query,
            "q": query,
            "search": query,
            "text": query,
            "max_results": 10,
            "maxResults": 10,
        ]
    }

    public static func shortFailure(_ value: Any, tool: String) -> String {
        if let object = value as? [String: Any] {
            if let results = (object["data"] as? [String: Any])?["results"] as? [[String: Any]] {
                for row in results {
                    let slug = (row["tool_slug"] as? String) ?? tool
                    let err = (row["error"] as? String)
                        ?? ((row["response"] as? [String: Any])?["error"] as? String)
                        ?? ((row["response"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String
                    if let err, !err.isEmpty {
                        let first = err.split(separator: "\n", omittingEmptySubsequences: true)
                            .first
                            .map(String.init) ?? err
                        return "\(slug): \(String(first.prefix(280)))"
                    }
                }
            }
            if let err = object["error"] as? String, !err.isEmpty {
                return "\(tool): \(String(err.prefix(280)))"
            }
        }
        let blob = stringify(value)
        if let range = blob.range(of: #"\"error\"\s*:\s*\"([^\"]+)\""#, options: .regularExpression) {
            let slice = String(blob[range])
                .replacingOccurrences(of: #"\"error\"\s*:\s*\""#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\\""))
            if !slice.isEmpty {
                return "\(tool): \(String(slice.prefix(280)))"
            }
        }
        return "Composio tool \(tool) failed."
    }

    /// Turn MULTI_EXECUTE JSON into a short readable list for the model + UI.
    public static func formatToolResult(_ value: Any, tool: String) -> String {
        if let lines = extractReadableLines(from: value), !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        let text = pretty(value)
        if text.count <= 800 { return text }
        return ContextCompactor.summarizePayload(text, head: 500, tail: 200)
    }

    public static func extractReadableLines(from value: Any) -> [String]? {
        var subjectHits: [String] = []
        walk(value) { key, raw in
            let k = key.lowercased()
            guard k == "subject" || k == "title" || k == "summary" || k == "snippet" else { return }
            guard let string = raw as? String, !string.isEmpty else { return }
            let line = "• \(string)"
            if !subjectHits.contains(line) { subjectHits.append(line) }
        }
        if subjectHits.count >= 2 { return Array(subjectHits.prefix(12)) }

        func lines(from bag: [Any]) -> [String] {
            var out: [String] = []
            for item in bag.prefix(10) {
                guard let row = item as? [String: Any] else { continue }
                let subject = (row["subject"] as? String)
                    ?? (row["Subject"] as? String)
                    ?? (row["snippet"] as? String)
                    ?? (row["preview"] as? String)
                    ?? ""
                let from = (row["from"] as? String)
                    ?? (row["sender"] as? String)
                    ?? (row["From"] as? String)
                    ?? ""
                if subject.isEmpty && from.isEmpty { continue }
                if from.isEmpty {
                    out.append("• \(subject)")
                } else {
                    out.append("• \(subject.isEmpty ? "(no subject)" : subject) — \(from)")
                }
            }
            return out
        }

        func bags(in object: [String: Any]) -> [[Any]] {
            var found: [[Any]] = []
            for key in ["messages", "emails", "items", "results"] {
                if let array = object[key] as? [Any], !array.isEmpty {
                    found.append(array)
                }
            }
            if let data = object["data"] as? [String: Any] {
                found.append(contentsOf: bags(in: data))
            }
            if let results = object["results"] as? [[String: Any]] {
                for row in results {
                    if let response = row["response"] as? [String: Any] {
                        found.append(contentsOf: bags(in: response))
                    }
                }
            }
            return found
        }

        if let object = value as? [String: Any] {
            for bag in bags(in: object) {
                let out = lines(from: bag)
                if !out.isEmpty { return out }
            }
        }
        return subjectHits.isEmpty ? nil : Array(subjectHits.prefix(12))
    }

    /// One-line card text for chat UI (full detail stays in the tool output for the model).
    public static func chatSummary(slug: String, query: String, result: String, failed: Bool) -> String {
        if failed {
            let first = result.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? result
            return String(first.prefix(160))
        }
        let bullets = result.split(separator: "\n").filter { $0.hasPrefix("•") }
        if !bullets.isEmpty {
            let q = query.isEmpty ? "" : " · \(query)"
            return "\(bullets.count) result\(bullets.count == 1 ? "" : "s")\(q)"
        }
        if result.count <= 120 { return result }
        return String(result.prefix(100)) + "…"
    }

    public static func normalizedReadQuery(slug: String, query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let placeholder = lower.isEmpty
            || lower == "list"
            || lower == "get"
            || lower == "search"
            || lower == "read"
        guard placeholder else { return trimmed }
        switch toolkitSlug(slug) {
        case "gmail": return "in:inbox"
        case "googlecalendar": return "primary"
        case "googledrive", "gdrive": return "mimeType != 'application/vnd.google-apps.folder'"
        default: return trimmed.isEmpty ? "list" : trimmed
        }
    }

    public static func multipleAccountChoices(in value: Any) -> [String]? {
        let blob: String
        if let text = value as? String {
            blob = text
        } else {
            blob = stringify(value)
        }
        guard blob.localizedCaseInsensitiveContains("Multiple"),
              blob.localizedCaseInsensitiveContains("account")
        else { return nil }
        let patterns = [
            #""((?:gmail|google)[^"]+)""#,
            #"\b((?:gmail|google)_[a-z0-9][a-z0-9_-]*)\b"#,
        ]
        var names: [String] = []
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(blob.startIndex..<blob.endIndex, in: blob)
            for match in regex?.matches(in: blob, range: range) ?? [] {
                guard match.numberOfRanges > 1,
                      let swift = Range(match.range(at: 1), in: blob)
                else { continue }
                var name = String(blob[swift])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\\\"' "))
                while name.hasSuffix("\\") { name.removeLast() }
                guard name.contains("_") || name.contains("-") else { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.isEmpty ? nil : names
    }

    public static func isFailedExecution(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["successful"] as? Bool == false { return true }
            if let data = object["data"] as? [String: Any],
               let errorCount = data["error_count"] as? Int,
               errorCount > 0 {
                return true
            }
        }
        let blob = stringify(value).lowercased()
        return blob.contains("\"successful\":false") || blob.contains("\"error_count\":1")
    }

    public static func resolveAccountChoice(requested: String?, available: [String]) -> String? {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return available.first }
        let needle = trimmed.lowercased()
        if let exact = available.first(where: { $0.lowercased() == needle }) { return exact }
        if let partial = available.first(where: { $0.lowercased().contains(needle) || needle.contains($0.lowercased()) }) {
            return partial
        }
        // Allow matching on the email-ish suffix: gmail_lerwa-gharry ↔ lerwa-gharry / deepgapnc
        let compact = needle.replacingOccurrences(of: "@gmail.com", with: "")
            .replacingOccurrences(of: " ", with: "")
        return available.first(where: {
            $0.lowercased().replacingOccurrences(of: "gmail_", with: "").contains(compact)
                || compact.contains($0.lowercased().replacingOccurrences(of: "gmail_", with: ""))
        }) ?? available.first
    }

    public static func catalogURL(backendURL: String, query: String, limit: Int = 200) -> URL? {
        var comps = URLComponents(string: "\(backendURL)/toolkits")
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: "usage"),
        ]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            items.append(URLQueryItem(name: "search", value: q))
        }
        comps?.queryItems = items
        return comps?.url
    }

    public static func parseCatalog(_ data: Data) throws -> [ConnectionItem] {
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let items = (json["items"] as? [Any]) ?? (json["data"] as? [Any]) ?? []
        let parsed: [ConnectionItem] = items.compactMap { raw in
            guard let object = raw as? [String: Any] else { return nil }
            let slug = ((object["slug"] as? String) ?? (object["key"] as? String) ?? (object["name"] as? String) ?? "")
                .lowercased()
            guard !slug.isEmpty else { return nil }
            let name = (object["name"] as? String) ?? slug
            let meta = object["meta"] as? [String: Any]
            let blurb = ((meta?["description"] as? String) ?? (object["description"] as? String) ?? "")
            let logo = (meta?["logo"] as? String) ?? (object["logo"] as? String)
            return ConnectionItem(slug: slug, name: name, logo: logo, blurb: String(blurb.prefix(90)))
        }
        if parsed.isEmpty { throw PluginError.rejected("empty catalog") }
        return parsed
    }

    public func listCatalog(query: String) async throws -> [ConnectionItem] {
        let key = (apiKey?.isEmpty == false ? apiKey : connectKey) ?? connectKey
        guard let url = Self.catalogURL(backendURL: backendURL, query: query) else {
            throw PluginError.rejected("bad Composio catalog URL")
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginError.rejected("Composio catalog HTTP \(status)")
        }
        return try Self.parseCatalog(data)
    }

    // MARK: MCP

    public func call(_ name: String, arguments: [String: Any]) async throws -> Any {
        guard let url = URL(string: connectURL) else { throw PluginError.rejected("bad Composio URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(connectKey, forHTTPHeaderField: "x-consumer-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginError.rejected("Composio MCP HTTP \(status)")
        }
        return try Self.parseMCP(String(data: data, encoding: .utf8) ?? "")
    }

    public static func parseMCP(_ text: String) throws -> Any {
        let line: String
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            line = text
        } else if let dataLine = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) {
            line = String(dataLine.dropFirst(6))
        } else {
            throw PluginError.rejected("empty Composio MCP response")
        }
        guard let raw = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw PluginError.rejected("Composio MCP was not JSON")
        }
        if let error = raw["error"] as? [String: Any] {
            throw PluginError.rejected((error["message"] as? String) ?? "Composio MCP error")
        }
        let result = raw["result"]
        if let content = ((result as? [String: Any])?["content"] as? [[String: Any]])?
            .first(where: { $0["type"] as? String == "text" })?["text"] as? String
        {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) {
                return parsed
            }
            return ["text": content]
        }
        return result ?? raw
    }

    public static func firstAuthURL(in value: Any) -> URL? {
        var found: [URL] = []
        walk(value) { _, raw in
            guard let string = raw as? String, string.lowercased().hasPrefix("http") else { return }
            if let url = URL(string: string) { found.append(url) }
        }
        if found.isEmpty {
            let raw = stringify(value).replacingOccurrences(of: "\\/", with: "/")
            let regex = try? NSRegularExpression(pattern: #"https://[^\s"\\]+"#)
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            found = (regex?.matches(in: raw, range: range) ?? []).compactMap { match in
                guard let swift = Range(match.range, in: raw) else { return nil }
                return URL(string: String(raw[swift]))
            }
        }
        return found.first(where: { url in
            let s = url.absoluteString.lowercased()
            return s.contains("composio") || s.contains("connect") || s.contains("auth") || s.contains("oauth")
        }) ?? found.first
    }

    public static func connected(in value: Any, toolkit: String) -> Bool {
        let key = toolkitSlug(toolkit)
        if let object = value as? [String: Any] {
            let results = ((object["data"] as? [String: Any])?["results"] as? [String: Any])
                ?? (object["results"] as? [String: Any])
            if let row = results?[key] as? [String: Any] ?? results?[toolkit] as? [String: Any] {
                if hasAuthLink(in: row) { return false }
                if row["connected"] as? Bool == true { return true }
                if isActiveStatus(row["status"] as? String) { return true }
                if let accounts = row["accounts"] as? [[String: Any]] {
                    let active = accounts.contains { account in
                        isActiveStatus(account["status"] as? String)
                    }
                    if active { return true }
                }
                if row["connected_account_id"] is String || row["id"] is String,
                   !hasAuthLink(in: row) {
                    // Some payloads omit status but still include the live account id.
                    if row["status"] == nil { return true }
                }
            }
        }
        let blob = stringify(value).lowercased()
        guard blob.contains(key) else { return false }
        if blob.contains("redirect_url") || blob.contains("\"status\":\"initiated\"") {
            return false
        }
        return blob.contains("\"connected\":true")
            || blob.contains("\"status\":\"active\"")
    }

    public static func accountIds(in value: Any, toolkit: String) -> [String] {
        let key = toolkitSlug(toolkit)
        let results = ((value as? [String: Any])?["data"] as? [String: Any])?["results"] as? [String: Any]
            ?? (value as? [String: Any])?["results"] as? [String: Any]
        let row = results?[key] as? [String: Any] ?? results?[toolkit] as? [String: Any]
        var ids: [String] = []
        if let accounts = row?["accounts"] as? [[String: Any]] {
            ids.append(contentsOf: accounts.compactMap { account in
                (account["id"] as? String)
                    ?? (account["account_id"] as? String)
                    ?? (account["connected_account_id"] as? String)
                    ?? (account["nanoid"] as? String)
            })
        }
        if let single = (row?["connected_account_id"] as? String)
            ?? (row?["account_id"] as? String)
            ?? (row?["id"] as? String) {
            ids.append(single)
        }
        var unique: [String] = []
        for id in ids where !id.isEmpty && !unique.contains(id) {
            unique.append(id)
        }
        return unique
    }

    private static func isActiveStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return status.lowercased() == "active"
    }

    private static func hasAuthLink(in row: [String: Any]) -> Bool {
        for key in ["redirect_url", "redirectUrl", "auth_url", "authUrl", "url"] {
            if let string = row[key] as? String, string.lowercased().hasPrefix("http") {
                return true
            }
        }
        return false
    }

    public static func toolSlugs(in value: Any) -> [String] {
        var found: [String] = []
        walk(value) { key, raw in
            guard key == "tool_slug" || key == "slug" || key == "name" || key == "tool" else { return }
            guard let string = raw as? String else { return }
            if string.range(of: #"^[A-Z][A-Z0-9_]{3,}$"#, options: .regularExpression) != nil {
                found.append(string)
            }
        }
        var unique: [String] = []
        for item in found where !unique.contains(item) {
            unique.append(item)
        }
        return unique
    }

    private static func walk(_ value: Any, visit: (String, Any) -> Void) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                visit(key, child)
                walk(child, visit: visit)
            }
        } else if let array = value as? [Any] {
            for child in array { walk(child, visit: visit) }
        }
    }

    private static func stringify(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func pretty(_ value: Any) -> String {
        if let text = (value as? [String: Any])?["text"] as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}

public final class ImmediateComposio: ComposioConnecting, @unchecked Sendable {
    public var connected: Set<String> = []
    public var lastAuthorize: String?
    public var executed: [(String, String, String)] = []
    public var catalog: [ConnectionItem] = ConnectionCatalog.defaults
    public var accountsBySlug: [String: [String]] = [:]
    public var lastAccount: String?
    public var searchedAccounts: [String] = []

    public init() {}

    public func authorizeURL(for slug: String) async throws -> URL {
        lastAuthorize = slug
        connected.insert(ComposioClient.toolkitSlug(slug))
        return URL(string: "https://connect.composio.dev/auth/\(slug)")!
    }

    public func isConnected(_ slug: String) async throws -> Bool {
        connected.contains(ComposioClient.toolkitSlug(slug))
    }

    public func disconnect(_ slug: String) async throws {
        connected.remove(ComposioClient.toolkitSlug(slug))
    }

    public func execute(slug: String, title: String, body: String, account: String?) async throws -> String {
        executed.append((slug, title, body))
        lastAccount = account
        if account == nil, let many = accountsBySlug[slug], many.count > 1 {
            throw PluginError.rejected(
                "Multiple accounts connected. Choose one in Plugins, or pass account: \(many.joined(separator: ", "))"
            )
        }
        return "composio://\(slug)/\(title)"
    }

    public func search(slug: String, query: String, account: String?) async throws -> String {
        lastAccount = account
        if let account { searchedAccounts.append(account) }
        if account == nil, let many = accountsBySlug[slug], many.count > 1 {
            throw PluginError.rejected(
                "Multiple accounts connected. Choose one in Plugins, or pass account: \(many.joined(separator: ", "))"
            )
        }
        let label = account.map { "\($0)/" } ?? ""
        return "composio-search://\(slug)/\(label)\(query)"
    }

    public func listAccounts(slug: String) async throws -> [String] {
        accountsBySlug[slug] ?? []
    }

    public func listCatalog(query: String) async throws -> [ConnectionItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return catalog }
        return catalog.filter {
            $0.name.lowercased().contains(q)
                || $0.slug.lowercased().contains(q)
                || $0.blurb.lowercased().contains(q)
        }
    }
}
