import Foundation

public enum WebSearchError: Error, LocalizedError, Equatable {
    case blocked
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .blocked:
            return "Search was blocked by the provider. Do not retry similar queries this turn."
        case .http(let code, let body):
            return WebSearch.fetchFailureMessage(status: code, bodyPreview: body)
        }
    }
}

/// Lightweight web search for bots (OpenMausBot `WebSearch` / Claude tool analogue).
/// DuckDuckGo first, Wikipedia OpenSearch fallback — no API key required.
public enum WebSearch: Sendable {
    public struct Result: Sendable, Equatable, Hashable {
        public var title: String
        public var url: String
        public var snippet: String

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }

    public static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    public static func search(query: String, limit: Int = 5) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var blocked = false
        if let instant = try? await instantAnswer(query: trimmed), !instant.isEmpty {
            return Array(instant.prefix(limit))
        }
        switch await htmlBackend(
            URL(string: "https://html.duckduckgo.com/html/?q=\(urlEncode(trimmed))"),
            limit: limit
        ) {
        case .results(let rows): return rows
        case .blocked: blocked = true
        case .empty: break
        }
        switch await htmlBackend(
            URL(string: "https://lite.duckduckgo.com/lite/?q=\(urlEncode(trimmed))"),
            limit: limit
        ) {
        case .results(let rows): return rows
        case .blocked: blocked = true
        case .empty: break
        }
        if let wiki = try? await wikipedia(query: trimmed, limit: limit), !wiki.isEmpty {
            return wiki
        }
        if blocked { throw WebSearchError.blocked }
        return []
    }

    /// Fetch a public http(s) page and return a truncated text extract.
    public static func fetch(url raw: String, maxBytes: Int = 80_000) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }
        let (data, http) = try await get(url, timeout: 15)
        let status = http?.statusCode ?? 0
        if status != 0, !(200..<300).contains(status) {
            let preview = String(data: data.prefix(400), encoding: .utf8)
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw WebSearchError.http(status, preview)
        }
        let slice = data.prefix(maxBytes)
        let rawText = String(data: slice, encoding: .utf8)
            ?? String(decoding: slice, as: UTF8.self)
        let stripped = stripTags(rawText)
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(12_000))
    }

    public static func fetchFailureMessage(status: Int, bodyPreview: String) -> String {
        let clipped = String(bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        if clipped.isEmpty {
            return "Fetch failed: HTTP \(status). Do not retry the same URL this turn."
        }
        return "Fetch failed: HTTP \(status) — \(clipped). Do not retry the same URL this turn."
    }

    public static func isBlockedPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        if lowered.contains("bots are not allowed") { return true }
        if lowered.contains("anomaly-modal") { return true }
        if lowered.contains("if this persists") && lowered.contains("duckduckgo") { return true }
        if lowered.contains("cloudflare") && (lowered.contains("challenge") || lowered.contains("attention required")) {
            return true
        }
        return false
    }

    public static func parseWikipediaOpenSearch(_ data: Data, limit: Int) throws -> [Result] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [Any], array.count >= 4,
              let titles = array[1] as? [String],
              let snippets = array[2] as? [String],
              let urls = array[3] as? [String] else {
            throw WebSearchError.http(200, "Wikipedia OpenSearch payload was not a 4-array")
        }
        var results: [Result] = []
        for idx in titles.indices {
            guard results.count < limit else { break }
            let title = titles[idx]
            let url = idx < urls.count ? urls[idx] : ""
            let snippet = idx < snippets.count ? snippets[idx] : ""
            if title.isEmpty || url.isEmpty { continue }
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    // MARK: - Instant Answer API

    private static func instantAnswer(query: String) async throws -> [Result] {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await get(url, timeout: 8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [Result] = []
        if let heading = json["Heading"] as? String, !heading.isEmpty,
           let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
            let absURL = (json["AbstractURL"] as? String) ?? ""
            results.append(Result(title: heading, url: absURL, snippet: abstract))
        }
        if let related = json["RelatedTopics"] as? [[String: Any]] {
            for topic in related {
                if let text = topic["Text"] as? String, let firstURL = topic["FirstURL"] as? String {
                    let title = text.split(separator: " - ").first.map(String.init) ?? text
                    results.append(Result(title: title, url: firstURL, snippet: text))
                } else if let topics = topic["Topics"] as? [[String: Any]] {
                    for nested in topics {
                        guard let text = nested["Text"] as? String,
                              let firstURL = nested["FirstURL"] as? String else { continue }
                        let title = text.split(separator: " - ").first.map(String.init) ?? text
                        results.append(Result(title: title, url: firstURL, snippet: text))
                    }
                }
            }
        }
        return results
    }

    private enum HTMLBackend {
        case results([Result])
        case blocked
        case empty
    }

    private static func htmlBackend(_ url: URL?, limit: Int) async -> HTMLBackend {
        guard let url else { return .empty }
        do {
            let (data, http) = try await get(url, timeout: 10)
            let status = http?.statusCode ?? 0
            if status != 0, !(200..<300).contains(status) { return .empty }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if isBlockedPage(html) { return .blocked }
            let parsed = parseHTMLResults(html, limit: limit)
            return parsed.isEmpty ? .empty : .results(parsed)
        } catch {
            return .empty
        }
    }

    private static func wikipedia(query: String, limit: Int) async throws -> [Result] {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "namespace", value: "0"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return [] }
        let (data, http) = try await get(url, timeout: 10)
        let status = http?.statusCode ?? 0
        if status != 0, !(200..<300).contains(status) { return [] }
        return try parseWikipediaOpenSearch(data, limit: limit)
    }

    // MARK: - HTML

    public static func parseHTMLResults(_ html: String, limit: Int) -> [Result] {
        var results: [Result] = []
        let linkPattern = /class="result__a"[^>]*href="(?<href>[^"]+)"[^>]*>(?<title>.*?)<\/a>/
        let altPattern = /class="result-link"[^>]*href="(?<href>[^"]+)"[^>]*>(?<title>.*?)<\/a>/
        let snippetPattern = /class="result__snippet"[^>]*>(?<snip>.*?)<\/(?:a|td|div)>/
        let nofollowPattern = /<a[^>]*rel="nofollow"[^>]*href="(?<href>https?:\/\/[^"]+)"[^>]*>(?<title>.*?)<\/a>/

        let snips = html.matches(of: snippetPattern)

        func append(href rawHref: String, title rawTitle: String, snippet: String) {
            guard results.count < limit else { return }
            let title = stripTags(rawTitle)
            let href = unwrapDuckRedirect(rawHref)
            if title.isEmpty || isJunkURL(href) { return }
            if results.contains(where: { $0.url == href }) { return }
            results.append(Result(title: title, url: href, snippet: snippet))
        }

        for (idx, match) in html.matches(of: linkPattern).enumerated() {
            let snippet = snips.indices.contains(idx) ? stripTags(String(snips[idx].snip)) : ""
            append(href: String(match.href), title: String(match.title), snippet: snippet)
        }
        for match in html.matches(of: altPattern) {
            append(href: String(match.href), title: String(match.title), snippet: "")
        }
        for match in html.matches(of: nofollowPattern) {
            append(href: String(match.href), title: String(match.title), snippet: "")
        }
        return results
    }

    private static func unwrapDuckRedirect(_ href: String) -> String {
        if let range = href.range(of: "uddg=") {
            let encoded = String(href[range.upperBound...])
                .split(separator: "&").first.map(String.init) ?? ""
            return encoded.removingPercentEncoding ?? href
        }
        if href.hasPrefix("//") { return "https:" + href }
        return href
    }

    private static func isJunkURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("duckduckgo.com") { return true }
        return false
    }

    private static func stripTags(_ html: String) -> String {
        html
            .replacing(/\s*<[^>]+>\s*/, with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }
}
