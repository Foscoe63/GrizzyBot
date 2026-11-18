import Foundation
import GrizzyBotCore
import Testing

@Suite("Voice activity and wake word")
struct VoiceActivityTests {
    private func run(_ levels: [(Float, Double)]) -> [VoiceActivityDetector.Event] {
        var vad = VoiceActivityDetector()
        return levels.compactMap { vad.process(level: $0.0, at: $0.1) }
    }

    @Test("speech starts after a short attack and ends after the hangover, not at a pause")
    func utterance() {
        var frames: [(Float, Double)] = []
        var t = 0.0
        func add(_ level: Float, seconds: Double) { for _ in 0..<Int(seconds / 0.05) { frames.append((level, t)); t += 0.05 } }
        add(0.003, seconds: 1)     // room noise
        add(0.1, seconds: 0.5)     // "hey"
        add(0.003, seconds: 0.4)   // a pause shorter than the hangover
        add(0.1, seconds: 0.5)     // "grizzy"
        add(0.003, seconds: 1.5)   // done
        #expect(run(frames) == [.speechStarted, .speechEnded])
    }

    @Test("a click shorter than the attack, and plain quiet, never start speech")
    func noise() {
        var frames: [(Float, Double)] = []
        for i in 0..<100 { frames.append((i == 20 ? 0.2 : 0.003, Double(i) * 0.05)) }
        #expect(run(frames).isEmpty)
    }

    @Test("a noisy room raises the floor so steady hum isn't speech")
    func hum() {
        let frames = (0..<200).map { (Float(0.02), Double($0) * 0.05) }
        // Constant hum is loud against the initial floor once, then the floor adapts only while quiet; it must
        // not flap on and off.
        #expect(run(frames).filter { $0 == .speechEnded }.count <= 1)
    }

    @Test("the wake phrase is matched at the start and the command is cut out intact")
    func wake() {
        #expect(WakeWordMatcher.command(in: "Hey Grizzy, what's on my calendar?") == "what's on my calendar?")
        #expect(WakeWordMatcher.command(in: "hey grizzly summarise my inbox") == "summarise my inbox")
        #expect(WakeWordMatcher.command(in: "Hey Grizzy") == "")
        #expect(WakeWordMatcher.command(in: "tell hey grizzy a story") == nil)
        #expect(WakeWordMatcher.command(in: "good morning") == nil)
    }

    @Test("the gate ignores chatter, waits after a bare wake phrase, and takes the next utterance")
    func gate() {
        #expect(HandsFreeGate.decide(utterance: "so anyway yesterday", awaiting: false) == .ignored)
        #expect(HandsFreeGate.decide(utterance: "hey grizzy", awaiting: false) == .awaitingCommand)
        #expect(HandsFreeGate.decide(utterance: "check the weather", awaiting: true) == .command("check the weather"))
        #expect(HandsFreeGate.decide(utterance: "hey grizzy check the weather", awaiting: false) == .command("check the weather"))
    }
}
