import Foundation

/// Rejects requests a web page could send to a local server (DNS rebinding, cross-site fetches).
///
/// A browser always sends `Host` and, for cross-site requests, `Origin`. Native MCP clients and
/// `curl` send no `Origin`, so refusing a foreign one costs them nothing.
public enum RequestOriginGuard {
    /// - Parameter loopbackOnly: the server is bound to loopback, so `Host` must name loopback too.
    ///   Otherwise (the companion listening on the network) `Host` may be any address, but an
    ///   `Origin` must still be the same site as `Host`.
    public static func allows(headers: [String: String], loopbackOnly: Bool) -> Bool {
        var host: String?
        if let raw = headers["host"] {
            // A Host header that is present but malformed is never legitimate.
            guard let parsed = hostName(raw) else { return false }
            host = parsed
        }
        if loopbackOnly, let host, !isLoopback(host) { return false }
        guard let origin = headers["origin"], !origin.isEmpty else { return true }
        // `null` is what sandboxed frames and some redirects send; no legitimate client does.
        guard let originHost = URLComponents(string: origin)?.host?.lowercased() else { return false }
        if loopbackOnly { return isLoopback(originHost) }
        guard let host else { return false }
        return originHost == host
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// The host part of a `Host` header, lowercased and without the port.
    static func hostName(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty else { return nil }
        func validPort(_ p: Substring) -> Bool { p.isEmpty || p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) }
        if v.hasPrefix("[") {
            guard let end = v.firstIndex(of: "]") else { return nil }
            let rest = v[v.index(after: end)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && validPort(rest.dropFirst())) else { return nil }
            return String(v[v.startIndex...end])
        }
        let parts = v.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 1 || validPort(parts[1]) else { return nil }
        return String(parts[0])
    }
}
