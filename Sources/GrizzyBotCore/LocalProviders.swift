import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum LocalProviderId: String, Codable, Sendable, CaseIterable, Identifiable {
    case ollama
    case lmstudio
    case vmlx
    case omlx

    public var id: String { rawValue }
}

public struct LocalModelRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String? = nil) {
        self.id = id
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmed.isEmpty ? id : trimmed
    }
}

public struct LocalProviderDef: Sendable, Hashable, Identifiable {
    public var id: LocalProviderId
    public var name: String
    public var defaultBaseUrl: String
    public var defaultPort: Int
    public var billing: String
}

public struct DiscoveredLocalProvider: Sendable, Hashable {
    public var provider: LocalProviderId
    public var providerName: String
    public var baseUrl: String
    public var reachable: Bool
    public var models: [LocalModelRef]
    public var error: String?
}

/// Ollama, LM Studio, vMLX, and oMLX — OpenAI-compatible local / LAN endpoints.
public enum LocalProviders {
    public static let all: [LocalProviderDef] = [
        LocalProviderDef(
            id: .ollama,
            name: "Ollama",
            defaultBaseUrl: "http://127.0.0.1:11434/v1",
            defaultPort: 11434,
            billing: "Runs on your machine or LAN. No cloud model charges."
        ),
        LocalProviderDef(
            id: .lmstudio,
            name: "LM Studio",
            defaultBaseUrl: "http://127.0.0.1:1234/v1",
            defaultPort: 1234,
            billing: "Runs on your machine or LAN. No cloud model charges."
        ),
        LocalProviderDef(
            id: .vmlx,
            name: "vMLX",
            defaultBaseUrl: "http://127.0.0.1:8000/v1",
            defaultPort: 8000,
            billing: "Apple Silicon MLX server on this Mac or LAN. No cloud model charges."
        ),
        LocalProviderDef(
            id: .omlx,
            name: "oMLX",
            defaultBaseUrl: "http://127.0.0.1:8000/v1",
            defaultPort: 8000,
            billing: "Apple Silicon MLX server on this Mac or LAN. No cloud model charges."
        ),
    ]

    private static let byId: [LocalProviderId: LocalProviderDef] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    public static func isLocal(_ provider: String) -> Bool {
        LocalProviderId(rawValue: provider) != nil
    }

    public static func def(for provider: String) -> LocalProviderDef? {
        guard let id = LocalProviderId(rawValue: provider) else { return nil }
        return byId[id]
    }

    public static func catalogEntries() -> [CatalogEntry] {
        all.map { entry in
            CatalogEntry(
                provider: entry.id.rawValue,
                providerName: entry.name,
                id: "\(entry.id.rawValue)/default",
                label: "Load models from \(entry.name)",
                billing: entry.billing,
                auth: .apiKey,
                subscription: false,
                kind: .local,
                defaultBaseUrl: entry.defaultBaseUrl,
                supportsBaseUrl: true
            )
        }
    }

    /// Normalize to an OpenAI-compatible root ending in `/v1` (no trailing slash).
    public static func normalizeBaseUrl(_ raw: String, provider: String? = nil) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            guard let fallback = provider.flatMap({ def(for: $0)?.defaultBaseUrl }) else {
                throw LocalProviderError.message("Base URL is required.")
            }
            return fallback
        }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw LocalProviderError.message("Base URL must be http or https.")
        }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            path = "v1"
        } else if !path.hasSuffix("/v1") && path != "v1" {
            path = "\(path)/v1"
        }
        components.path = "/\(path)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw LocalProviderError.message("Base URL is invalid.")
        }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func assertPrivateProviderUrl(_ baseUrl: String) throws -> URL {
        guard let url = URL(string: baseUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw LocalProviderError.message("Only http(s) provider URLs are allowed.")
        }
        let host = (url.host ?? "").lowercased()
        if host == "localhost" || host.hasSuffix(".local") { return url }
        if isPrivateOrLoopbackIP(host) { return url }
        throw LocalProviderError.message(
            "Provider base URL must target localhost or a private LAN address (10/8, 172.16/12, 192.168/16)."
        )
    }

    public static func isPrivateOrLoopbackIP(_ host: String) -> Bool {
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0]
        let b = parts[1]
        if a == 127 { return true }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        return false
    }

    /// GET `{base}/models` (OpenAI-compatible).
    public static func probeModels(
        baseUrl: String,
        apiKey: String? = nil,
        timeoutSeconds: TimeInterval = 4
    ) async throws -> (baseUrl: String, models: [LocalModelRef]) {
        let normalized = try normalizeBaseUrl(baseUrl)
        _ = try assertPrivateProviderUrl(normalized)
        guard let url = URL(string: "\(normalized)/models") else {
            throw LocalProviderError.message("Base URL is invalid.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
            throw LocalProviderError.message(
                "Timed out reaching the provider. Check the base URL and LAN access."
            )
        } catch {
            throw LocalProviderError.message(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LocalProviderError.message("Could not list models. Is the server reachable?")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalProviderError.message(
                "Could not list models (\(http.statusCode)). Is the server reachable?"
            )
        }

        let models = try parseModelsJSON(data)
        return (normalized, models)
    }

    /// Probe known local OpenAI-compatible ports on localhost and/or a LAN host.
    public static func discover(
        host: String? = nil,
        includeLocalhost: Bool = true
    ) async throws -> (hosts: [String], providers: [DiscoveredLocalProvider]) {
        var hosts = Set<String>()
        if includeLocalhost { hosts.insert("127.0.0.1") }
        if let raw = host?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if cleaned != "127.0.0.1" && cleaned != "localhost" {
                if !isPrivateOrLoopbackIP(cleaned)
                    && !cleaned.hasSuffix(".local")
                    && cleaned != "localhost" {
                    throw LocalProviderError.message(
                        "Discover host must be a private LAN address or .local name."
                    )
                }
                hosts.insert(cleaned)
            }
        }

        var results: [DiscoveredLocalProvider] = []
        await withTaskGroup(of: DiscoveredLocalProvider.self) { group in
            for hostName in hosts {
                for def in all {
                    let base = "http://\(hostName):\(def.defaultPort)/v1"
                    group.addTask {
                        do {
                            let probed = try await probeModels(baseUrl: base)
                            return DiscoveredLocalProvider(
                                provider: def.id,
                                providerName: def.name,
                                baseUrl: probed.baseUrl,
                                reachable: true,
                                models: probed.models
                            )
                        } catch {
                            return DiscoveredLocalProvider(
                                provider: def.id,
                                providerName: def.name,
                                baseUrl: base,
                                reachable: false,
                                models: [],
                                error: (error as? LocalProviderError)?.message
                                    ?? error.localizedDescription
                            )
                        }
                    }
                }
            }
            for await row in group {
                results.append(row)
            }
        }
        return (listLocalLanIPv4Addresses(), results)
    }

    public static func listLocalLanIPv4Addresses() -> [String] {
        #if canImport(Darwin)
        var addresses = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(
                decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if isPrivateOrLoopbackIP(ip) { addresses.insert(ip) }
        }
        return addresses.sorted()
        #else
        return []
        #endif
    }

    public static func parseModelsJSON(_ data: Data) throws -> [LocalModelRef] {
        struct Envelope: Decodable {
            struct Row: Decodable {
                var id: String?
                var name: String?
            }
            var data: [Row]?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var models: [LocalModelRef] = []
        var seen = Set<String>()
        for row in envelope.data ?? [] {
            let id = row.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            models.append(LocalModelRef(id: id, label: row.name))
        }
        return models
    }
}

public enum LocalProviderError: Error, LocalizedError, Sendable {
    case message(String)

    public var message: String {
        switch self {
        case .message(let text): return text
        }
    }

    public var errorDescription: String? { message }
}
