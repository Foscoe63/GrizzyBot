import Foundation
import GrizzyBotCore
import Testing

@Suite("Audit chain")
struct AuditChainTests {
    private func log(_ count: Int) -> [AuditEvent] {
        var events: [AuditEvent] = []
        for i in 0..<count {
            events = AuditLog.appending(events, AuditEvent(type: .agentInvoked, actorId: "me", botId: "b", tool: "t\(i)", reason: "event \(i)"))
        }
        return events
    }

    @Test("an untouched log verifies")
    func intact() {
        let v = AuditChain.verify(log(6))
        #expect(v.intact)
        #expect(v.checked == 6)
        #expect(v.summary.contains("intact"))
    }

    @Test("editing, deleting, or reordering an event is detected")
    func tamper() {
        var edited = log(6)
        edited[3].reason = "nothing to see here"
        #expect(AuditChain.verify(edited).brokenAt == 3)

        var deleted = log(6)
        deleted.remove(at: 2)
        #expect(AuditChain.verify(deleted).brokenAt == 2)

        var swapped = log(6)
        swapped.swapAt(1, 2)
        #expect(AuditChain.verify(swapped).intact == false)
    }

    @Test("events from before chaining are skipped, then the chain picks up")
    func legacy() {
        var events: [AuditEvent] = [AuditEvent(type: .agentInvoked, actorId: "me", reason: "old")]
        events = AuditLog.appending(events, AuditEvent(type: .agentInvoked, actorId: "me", reason: "new 1"))
        events = AuditLog.appending(events, AuditEvent(type: .agentInvoked, actorId: "me", reason: "new 2"))
        // The legacy first event carries no chain.
        events[0].chain = nil
        let v = AuditChain.verify(events)
        #expect(v.intact && v.unchained == 1 && v.checked == 2)
    }

    @Test("a trimmed log still verifies and a round trip through JSON keeps the chain")
    func trimmedAndCodable() throws {
        let events = log(8)
        let tail = Array(events.suffix(5))
        #expect(AuditChain.verify(tail).intact)
        let data = try JSONEncoder().encode(events)
        let back = try JSONDecoder().decode([AuditEvent].self, from: data)
        #expect(back == events)
        #expect(AuditChain.verify(back).intact)
        // An old file without the field still loads.
        let legacy = try JSONDecoder().decode(AuditEvent.self, from: Data(#"{"id":"1","type":"agent.invoked","at":0,"actorId":"x","reason":"r","attributes":{}}"#.utf8))
        #expect(legacy.chain == nil)
    }
}

@Suite("Audit locality and export")
struct AuditLocalityTests {
    @Test("remote calls are tagged remote, blocked ones local")
    func infer() {
        #expect(AuditEvent(type: .agentInvoked, actorId: "me", tool: "web_fetch", reason: "x").locality == .remote)
        #expect(AuditEvent(type: .agentInvoked, actorId: "me", tool: "read_file", reason: "x").locality == .local)
        #expect(AuditEvent(type: .secretLeakBlocked, actorId: "me", tool: "web_fetch", forwarded: false, reason: "x").locality == .local)
    }

    @Test("an export re-verifies outside the app")
    func export() throws {
        var events: [AuditEvent] = []
        for i in 0..<5 {
            events = AuditLog.appending(events, AuditEvent(
                type: .agentInvoked, actorId: "me", botId: "b", tool: i % 2 == 0 ? "web_fetch" : "shell",
                allowed: true, forwarded: true, reason: "path /a/b é \(i)",
                attributes: ["n": .number(Double(i)), "url": .string("https://x.example/a")]
            ))
        }
        #expect(AuditExport.remoteEvents(events).count == 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        try AuditExport.jsonLines(events).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/verify-audit.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "\(out)")
        #expect(out.contains("5 verified"))
    }
}
