import Foundation
import GrizzyBotCore
import Testing

@Suite("MCP reprobe")
@MainActor
struct McpReprobeTests {
    private func tempStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.appConfig.enableFolderWatchers = false
        return store
    }

    @Test("only failed servers are re-probed")
    func onlyFailedReprobed() {
        let store = tempStore()
        let a = store.addMcpServer(name: "a", transport: .http, command: "", args: [], env: [:], url: "http://127.0.0.1:9/mcp", headers: [:])!
        let b = store.addMcpServer(name: "b", transport: .http, command: "", args: [], env: [:], url: "http://127.0.0.1:9/mcp", headers: [:])!
        store.mcpProbeStatus[a.id] = .failed("down")
        store.mcpProbeStatus[b.id] = .connected(toolCount: 3)
        let probed = store.reprobeFailedMcpServers()
        #expect(probed == [a.id])
        #expect(store.mcpProbeStatus[a.id] == .checking)
        #expect(store.mcpProbeStatus[b.id] == .connected(toolCount: 3))
        store.stopMcpReprobeLoop()
    }
}
