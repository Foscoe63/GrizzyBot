import Foundation
import GrizzyBotCore
import Testing

@Suite("MLX residency")
struct MLXResidencyTests {
    @Test("idle unload waits for the timeout and never interrupts a reply")
    func idle() {
        let r = MLXResidency()
        r.idleSeconds = 300
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!r.shouldUnloadForIdle(now: t0), "nothing loaded yet")
        r.begin(now: t0)
        #expect(!r.shouldUnloadForIdle(now: t0.addingTimeInterval(10_000)), "still generating")
        r.end(now: t0.addingTimeInterval(5))
        #expect(!r.shouldUnloadForIdle(now: t0.addingTimeInterval(200)))
        #expect(r.shouldUnloadForIdle(now: t0.addingTimeInterval(400)))
        r.unloaded()
        #expect(!r.shouldUnloadForIdle(now: t0.addingTimeInterval(9_999)))
    }

    @Test("memory pressure frees an idle model but not a busy one")
    func pressure() {
        let r = MLXResidency()
        r.begin()
        #expect(!r.shouldUnloadForPressure())
        r.end()
        #expect(r.shouldUnloadForPressure())
    }
}
