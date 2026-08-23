import Foundation

/// Local network MCP discovery (`_mcp._tcp` on `local.`).
public enum MCPBonjourDiscovery {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { "\(name)@\(host):\(port)" }
        public var name: String
        public var host: String
        public var port: Int

        public init(name: String, host: String, port: Int) {
            self.name = name
            self.host = host
            self.port = port
        }

        public var httpBaseURL: String {
            "http://\(host):\(port)"
        }
    }

    public static func discover(timeoutSeconds: TimeInterval = 5) async -> [Entry] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Entry], Never>) in
            var resumed = false
            let resumeLock = NSLock()
            func finishOnce(_ entries: [Entry]) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: entries)
            }

            let session = BrowseSession()
            session.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                session.stop()
                finishOnce(session.entries)
            }
        }
    }

    private final class BrowseSession: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
        private var browser: NetServiceBrowser?
        private let lock = NSLock()
        fileprivate(set) var entries: [Entry] = []

        func start() {
            let b = NetServiceBrowser()
            browser = b
            b.delegate = self
            b.includesPeerToPeer = true
            b.searchForServices(ofType: "_mcp._tcp", inDomain: "local.")
        }

        func stop() {
            browser?.stop()
            browser = nil
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
            service.delegate = self
            service.resolve(withTimeout: 5)
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let host = (sender.hostName ?? "127.0.0.1").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let port = sender.port
            let short = sender.name
            lock.lock()
            entries.append(Entry(name: short, host: host, port: port))
            lock.unlock()
        }

        func netService(_ sender: NetService, didNotResolve error: [String: NSNumber]) {}
    }
}
