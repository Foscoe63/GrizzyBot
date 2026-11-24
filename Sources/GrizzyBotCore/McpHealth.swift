import Foundation

/// Limits that keep one misbehaving MCP server from flooding memory.
public enum McpLimits {
    /// The most one response (a stdio line stream or an HTTP body) may hold.
    public static let maxResponseBytes = 16 * 1024 * 1024
}

/// What the last calls to one MCP server did. Kept on disk so Settings can show a server that has been failing
/// across restarts. Holds only counts, times and a short normalized reason: never arguments or output.
public struct McpServerHealth: Codable, Sendable, Equatable {
    public var lastOK: Date?
    public var lastFailure: Date?
    public var lastReason: String?
    public var consecutiveFailures: Int = 0
    public var totalCalls: Int = 0

    public var isDegraded: Bool { consecutiveFailures >= 3 }

    public var summary: String {
        if consecutiveFailures > 0, let reason = lastReason {
            return "\(consecutiveFailures) failed in a row — \(reason)"
        }
        if let lastOK { return "Working — last answered \(lastOK.formatted(.relative(presentation: .named)))" }
        return "No calls yet"
    }
}

public final class McpHealthBook: @unchecked Sendable {
    public static let shared = McpHealthBook()
    private let lock = NSLock()
    private var servers: [String: McpServerHealth] = [:]
    private var fileURL: URL?

    public init() {}

    /// Points the book at its file and loads what is there.
    public func attach(to url: URL) {
        lock.lock(); defer { lock.unlock() }
        fileURL = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: McpServerHealth].self, from: data) {
            servers = saved
        } else {
            servers = [:]
        }
    }

    public func health(for serverId: String) -> McpServerHealth? {
        lock.lock(); defer { lock.unlock() }
        return servers[serverId]
    }

    public func recordSuccess(serverId: String, now: Date = .now) {
        update(serverId) { h in
            h.lastOK = now; h.consecutiveFailures = 0; h.lastReason = nil; h.totalCalls += 1
        }
    }

    public func recordFailure(serverId: String, error: Error, now: Date = .now) {
        let reason = FailureSignature.normalize(error.localizedDescription)
        update(serverId) { h in
            h.lastFailure = now; h.consecutiveFailures += 1; h.lastReason = reason; h.totalCalls += 1
        }
    }

    public func forget(serverId: String) { update(serverId, remove: true) { _ in } }

    private func update(_ id: String, remove: Bool = false, _ change: (inout McpServerHealth) -> Void) {
        lock.lock()
        var h = servers[id] ?? McpServerHealth()
        change(&h)
        servers[id] = remove ? nil : h
        let snapshot = servers, url = fileURL
        lock.unlock()
        if let url, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
