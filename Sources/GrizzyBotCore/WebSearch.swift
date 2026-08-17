import Foundation

/// Lightweight web search for bots (OpenMausBot `WebSearch` / Claude tool analogue).
/// Uses DuckDuckGo Instant Answer + HTML fallback — no API key required.
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

    public static func search(query: String, limit: Int = 5) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let instant = try? await instantAnswer(query: trimmed), !instant.isEmpty {
            return Array(instant.prefix(limit))
        }
        return try await htmlSearch(query: trimmed, limit: limit)
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
        var request = URLRequest(url: url)
        request.setValue("GrizzyBot/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
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
                    let snippet = text
                    results.append(Result(title: title, url: firstURL, snippet: snippet))
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

    // MARK: - HTML fallback

    private static func htmlSearch(query: String, limit: Int) async throws -> [Result] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 GrizzyBot/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseHTMLResults(html, limit: limit)
    }

    public static func parseHTMLResults(_ html: String, limit: Int) -> [Result] {
        var results: [Result] = []
        // result__a links and result__snippet blocks
        let linkPattern = /class="result__a"[^>]*href="(?<href>[^"]+)"[^>]*>(?<title>.*?)<\/a>/
        let snippetPattern = /class="result__snippet"[^>]*>(?<snip>.*?)<\/(?:a|td|div)>/

        let links = html.matches(of: linkPattern)
        let snips = html.matches(of: snippetPattern)

        for (idx, match) in links.enumerated() {
            guard results.count < limit else { break }
            let rawHref = String(match.href)
            let title = stripTags(String(match.title))
            let href = unwrapDuckRedirect(rawHref)
            let snippet: String
            if snips.indices.contains(idx) {
                snippet = stripTags(String(snips[idx].snip))
            } else {
                snippet = ""
            }
            if title.isEmpty { continue }
            results.append(Result(title: title, url: href, snippet: snippet))
        }
        return results
    }

    private static func unwrapDuckRedirect(_ href: String) -> String {
        // //duckduckgo.com/l/?uddg=https%3A%2F%2F...
        if let range = href.range(of: "uddg=") {
            let encoded = String(href[range.upperBound...])
                .split(separator: "&").first.map(String.init) ?? ""
            return encoded.removingPercentEncoding ?? href
        }
        if href.hasPrefix("//") { return "https:" + href }
        return href
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
}
