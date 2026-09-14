import Foundation

/// Keeps initialized MCP sessions alive across calls.
///
/// Every `McpClient` entry point used to open a session, run the `initialize` handshake, make one
/// request and tear the whole thing down. For a stdio server launched through `npx` that is
/// seconds of cold start on *every* tool call — paid again by each retry, and again by the tool
/// listing that precedes it. MCP sessions are designed to be long-lived; this pool treats them
/// that way, handing out a ready session until it dies or goes idle.
public actor McpSessionPool {
    public static let shared = McpSessionPool()

    /// How long an unused session is kept before being closed. Long enough to span a multi-step
    /// agent turn, short enough that idle servers do not sit around holding resources.
    public static let idleTimeout: TimeInterval = 180
    /// Upper bound on live sessions; past this the least recently used is closed.
    public static let maxSessions = 8

    private struct Entry {
        var session: any McpSession
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]
    /// In-flight opens, so concurrent callers for one server await a single spawn.
    private var opening: [String: Task<any McpSession, Error>] = [:]

    private init() {}

    /// Identity of a *configuration*, not just a server id: editing the command, args, env, URL
    /// or headers must produce a new process rather than silently reuse the old one.
    nonisolated static func fingerprint(_ server: McpServer) -> String {
        func pairs(_ dict: [String: String]) -> String {
            dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        return [
            server.id,
            String(describing: server.transport),
            server.command,
            server.args.joined(separator: " "),
            pairs(server.env),
            server.url,
            pairs(server.headers),
        ].joined(separator: "\u{1}")
    }

    /// An initialized session for `server`, reusing a live one when there is one.
    /// Internal: `McpSession` is a transport detail, so callers outside the module go through
    /// `McpClient.call` / `listTools` / `invoke`.
    func session(for server: McpServer, timeout: TimeInterval) async throws -> any McpSession {
        let key = Self.fingerprint(server)
        await sweepIdle()

        if let entry = entries[key] {
            if entry.session.isAlive {
                entries[key]?.lastUsed = Date()
                entry.session.setRequestTimeout(timeout)
                return entry.session
            }
            entries.removeValue(forKey: key)
            await entry.session.close()
        }

        if let inFlight = opening[key] {
            let session = try await inFlight.value
            session.setRequestTimeout(timeout)
            return session
        }

        let task = Task<any McpSession, Error> {
            let session = try await McpClient.openSession(server: server, timeout: timeout)
            do {
                _ = try await McpClient.initialize(session: session)
            } catch {
                // A session that failed its handshake is not reusable.
                await session.close()
                throw error
            }
            return session
        }
        opening[key] = task

        do {
            let session = try await task.value
            opening.removeValue(forKey: key)
            entries[key] = Entry(session: session, lastUsed: Date())
            await evictOverflow()
            session.setRequestTimeout(timeout)
            return session
        } catch {
            opening.removeValue(forKey: key)
            throw error
        }
    }

    /// Drop a server's session so the next call opens a fresh one. Safe to call when there is none.
    public func invalidate(_ server: McpServer) async {
        guard let entry = entries.removeValue(forKey: Self.fingerprint(server)) else { return }
        await entry.session.close()
    }

    /// Close everything — app termination, or a settings change that rewrites every server.
    public func shutdown() async {
        let live = Array(entries.values)
        entries.removeAll()
        opening.removeAll()
        for entry in live {
            await entry.session.close()
        }
    }

    /// Diagnostics and tests.
    public func liveSessionCount() -> Int {
        entries.count
    }

    private func sweepIdle() async {
        let cutoff = Date().addingTimeInterval(-Self.idleTimeout)
        for (key, entry) in entries where entry.lastUsed < cutoff || !entry.session.isAlive {
            entries.removeValue(forKey: key)
            await entry.session.close()
        }
    }

    private func evictOverflow() async {
        guard entries.count > Self.maxSessions else { return }
        let overflow = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(entries.count - Self.maxSessions)
        for (key, entry) in overflow {
            entries.removeValue(forKey: key)
            await entry.session.close()
        }
    }
}

extension McpError {
    /// Whether this failure means the *session* is gone, as opposed to the server having
    /// answered with an error. Only the former justifies discarding a pooled session.
    var invalidatesSession: Bool {
        switch self {
        case .transport, .cancelled, .launchFailed:
            return true
        case .timeout:
            // The server may be wedged rather than dead. Drop the session so the next call gets a
            // fresh process, but this one does not retry — that would double an already long wait.
            return true
        case .remote, .invalidConfiguration, .protocolError, .noTools:
            return false
        }
    }

    /// Failures worth one immediate retry on a fresh session. A timeout is excluded: retrying
    /// costs another full deadline.
    var deservesFreshSessionRetry: Bool {
        switch self {
        case .transport, .cancelled:
            return true
        default:
            return false
        }
    }
}
