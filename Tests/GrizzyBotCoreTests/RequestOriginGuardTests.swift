import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Request origin guard")
struct RequestOriginGuardTests {
    @Test("loopback servers accept loopback hosts and no Origin")
    func loopbackAccepted() {
        for host in ["127.0.0.1:8801", "localhost:8801", "localhost", "[::1]:8801", "LOCALHOST"] {
            #expect(RequestOriginGuard.allows(headers: ["host": host], loopbackOnly: true), "\(host)")
        }
        #expect(RequestOriginGuard.allows(headers: [:], loopbackOnly: true))
        #expect(RequestOriginGuard.allows(headers: ["host": "localhost:1", "origin": "http://localhost:3000"], loopbackOnly: true))
    }

    @Test("a rebound DNS name or a foreign Origin is refused on loopback")
    func loopbackRefused() {
        #expect(!RequestOriginGuard.allows(headers: ["host": "evil.example:8801"], loopbackOnly: true))
        #expect(!RequestOriginGuard.allows(headers: ["host": "127.0.0.1:8801.evil.example"], loopbackOnly: true))
        #expect(!RequestOriginGuard.allows(headers: ["host": "127.0.0.1", "origin": "https://evil.example"], loopbackOnly: true))
        #expect(!RequestOriginGuard.allows(headers: ["host": "127.0.0.1", "origin": "null"], loopbackOnly: true))
    }

    @Test("a network-facing server accepts any Host but only a same-site Origin")
    func networkMode() {
        #expect(RequestOriginGuard.allows(headers: ["host": "192.168.1.5:8802"], loopbackOnly: false))
        #expect(RequestOriginGuard.allows(headers: ["host": "192.168.1.5:8802", "origin": "http://192.168.1.5:8802"], loopbackOnly: false))
        #expect(!RequestOriginGuard.allows(headers: ["host": "192.168.1.5:8802", "origin": "https://evil.example"], loopbackOnly: false))
        #expect(!RequestOriginGuard.allows(headers: ["origin": "http://192.168.1.5:8802"], loopbackOnly: false))
    }

    @Test("the control plane and companion routes return 403 for a foreign Origin")
    func routes() async {
        let headers = ["authorization": "Bearer s3cret", "host": "127.0.0.1:8801", "origin": "https://evil.example"]
        let cp = await ControlPlaneServer().routeForTesting(
            HTTPRequestParser.Request(method: "POST", path: "/mcp", headers: headers), token: "s3cret", backend: ControlPlaneNoop())
        #expect(cp.0 == 403)
    }
}

private struct ControlPlaneNoop: ControlPlaneBackend {
    func listBots() async -> [ControlPlaneBot] { [] }
    func status(bot: String) async -> String? { nil }
    func recentMessages(bot: String, limit: Int) async -> [String]? { nil }
    func search(query: String, bot: String?) async -> [String] { [] }
    func send(bot: String, text: String, waitSeconds: Int) async -> String { "" }
    func interrupt(bot: String) async -> String { "" }
    func setModel(bot: String, provider: String, model: String) async -> String { "" }
}
