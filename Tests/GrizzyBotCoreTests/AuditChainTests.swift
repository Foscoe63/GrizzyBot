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
