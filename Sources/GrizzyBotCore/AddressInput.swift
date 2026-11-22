import Foundation

/// Turns what a person types in the browser's address bar into a page to load. Only http and https pages are ever
/// produced: `javascript:`, `file:`, `data:` and the like are refused, never searched for.
public enum AddressInput {
    public static let searchBase = "https://duckduckgo.com/?q="

    public static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000, !text.contains("\n") else { return nil }

        // An explicit scheme: allowed only when it is web.
        if let range = text.range(of: "://"), !text[..<range.lowerBound].contains(where: { $0 == " " || $0 == "." }) {
            let scheme = text[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            return webURL(text)
        }
        // "javascript:alert(1)", "data:text/html,…", "file:…", "mailto:x": a scheme with no slashes. A host with a port
        // ("localhost:3000", "example.com:8080") is not one.
        if let colon = text.firstIndex(of: ":") {
            let head = text[..<colon]
            let tail = text[text.index(after: colon)...]
            let isPort = !tail.isEmpty && tail.prefix(while: \.isNumber).count > 0 && (tail.drop(while: \.isNumber).first.map { $0 == "/" } ?? true)
            if !isPort, !head.contains(where: { $0 == " " || $0 == "." || $0 == "/" }), head.allSatisfy({ $0.isLetter }) { return nil }
        }
        if looksLikeAddress(text) { return webURL("https://" + text) }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchBase + query)
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// One word that is a host name: has a dot or is `localhost`, and no spaces.
    private static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name.lowercased() == "localhost" || (name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix("."))
    }
}
