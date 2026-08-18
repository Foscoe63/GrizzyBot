import Foundation

public protocol ComposioConnecting: Sendable {
    func authorizeURL(for slug: String) async throws -> URL
    func isConnected(_ slug: String) async throws -> Bool
    func disconnect(_ slug: String) async throws
    func execute(slug: String, title: String, body: String) async throws -> String
    func search(slug: String, query: String) async throws -> String
    func listCatalog(query: String) async throws -> [ConnectionItem]
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

    public func authorizeURL(for slug: String) async throws -> URL {
        let toolkit = Self.toolkitSlug(slug)
        let out = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: [
                "toolkits": [
                    ["name": toolkit, "action": "add"],
                ],
            ]
        )
        if let url = Self.firstAuthURL(in: out) { return url }
        let retry = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: ["toolkits": [toolkit]]
        )
        if let url = Self.firstAuthURL(in: retry) { return url }
        throw PluginError.rejected("Composio returned no sign-in link for \(slug).")
    }

    public func isConnected(_ slug: String) async throws -> Bool {
        let toolkit = Self.toolkitSlug(slug)
        let out = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: [
                "toolkits": [
                    ["name": toolkit, "action": "list"],
                ],
            ]
        )
        return Self.connected(in: out, toolkit: toolkit)
    }

    public func disconnect(_ slug: String) async throws {
        let toolkit = Self.toolkitSlug(slug)
        let listed = try await call(
            "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: [
                "toolkits": [
                    ["name": toolkit, "action": "list"],
                ],
            ]
        )
        let ids = Self.accountIds(in: listed, toolkit: toolkit)
        for id in ids {
            _ = try await call(
                "COMPOSIO_MANAGE_CONNECTIONS",
                arguments: [
                    "toolkits": [
                        ["name": toolkit, "action": "remove", "account_id": id],
                    ],
                ]
            )
        }
    }

    public func execute(slug: String, title: String, body: String) async throws -> String {
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
        let executed = try await call(
            "COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: [
                "tools": [[
                    "tool_slug": tool,
                    "arguments": [
                        "title": title,
                        "body": body,
                        "text": body,
                        "content": body,
                        "message": body,
                        "subject": title,
                    ],
                ]],
            ]
        )
        let text = Self.pretty(executed)
        if text.isEmpty { return "\(slug) via Composio (\(tool))" }
        return String(text.prefix(4_000))
    }

    public func search(slug: String, query: String) async throws -> String {
        let toolkit = Self.toolkitSlug(slug)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = try await call(
            "COMPOSIO_SEARCH_TOOLS",
            arguments: [
                "queries": [q.isEmpty ? "list \(toolkit)" : q],
                "toolkits": [toolkit],
            ]
        )
        let tools = Self.toolSlugs(in: search)
        let readTool = tools.first { slug in
            let upper = slug.uppercased()
            return upper.contains("LIST") || upper.contains("SEARCH") || upper.contains("GET")
                || upper.contains("FETCH") || upper.contains("FIND") || upper.contains("READ")
        } ?? tools.first
        guard let readTool else {
            throw PluginError.rejected("No Composio read tool found for \(slug).")
        }
        let executed = try await call(
            "COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: [
                "tools": [[
                    "tool_slug": readTool,
                    "arguments": [
                        "query": q,
                        "q": q,
                        "search": q,
                        "text": q,
                    ],
                ]],
            ]
        )
        let text = Self.pretty(executed)
        if text.isEmpty { return "\(slug) search via \(readTool)" }
        return String(text.prefix(4_000))
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
        if let object = value as? [String: Any] {
            let results = ((object["data"] as? [String: Any])?["results"] as? [String: Any])
                ?? (object["results"] as? [String: Any])
            if let row = results?[toolkit] as? [String: Any] {
                if row["connected"] as? Bool == true { return true }
                if let status = row["status"] as? String, status.lowercased() == "active" { return true }
                if let accounts = row["accounts"] as? [[String: Any]] {
                    return accounts.contains { account in
                        ((account["status"] as? String) ?? "").lowercased().contains("active")
                    }
                }
            }
        }
        let blob = stringify(value).lowercased()
        guard blob.contains(toolkit.lowercased()) else { return false }
        return blob.contains("\"connected\":true") || blob.contains("\"status\":\"active\"")
    }

    public static func accountIds(in value: Any, toolkit: String) -> [String] {
        let results = ((value as? [String: Any])?["data"] as? [String: Any])?["results"] as? [String: Any]
            ?? (value as? [String: Any])?["results"] as? [String: Any]
        let row = results?[toolkit] as? [String: Any]
        let accounts = (row?["accounts"] as? [[String: Any]]) ?? []
        return accounts.compactMap { account in
            (account["id"] as? String) ?? (account["account_id"] as? String) ?? (account["nanoid"] as? String)
        }
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

    public func execute(slug: String, title: String, body: String) async throws -> String {
        executed.append((slug, title, body))
        return "composio://\(slug)/\(title)"
    }

    public func search(slug: String, query: String) async throws -> String {
        "composio-search://\(slug)/\(query)"
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
