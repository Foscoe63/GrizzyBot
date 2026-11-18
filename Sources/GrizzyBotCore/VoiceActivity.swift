import Foundation

/// Finds where speech starts and stops in a stream of audio levels, so a hands-free listener only runs
/// speech recognition on real utterances. Energy based, with a noise floor that tracks the room and two
/// thresholds (hysteresis) so a pause between words doesn't end the utterance.
public struct VoiceActivityDetector: Sendable {
    public enum Event: Equatable, Sendable { case speechStarted, speechEnded }

    public struct Config: Sendable {
        /// Speech must rise this many times above the noise floor to start.
        public var startRatio: Float = 3.0
        /// …and fall under this many times the floor to count as quiet.
        public var stopRatio: Float = 1.6
        /// Loudness below this is silence whatever the floor says.
        public var minimumLevel: Float = 0.008
        /// Quiet this long (seconds) after speech ends the utterance.
        public var hangover: TimeInterval = 0.9
        /// Loud this long (seconds) before it counts as speech, so a click doesn't start one.
        public var attack: TimeInterval = 0.12
        public init() {}
    }

    public private(set) var isSpeaking = false
    public private(set) var noiseFloor: Float = 0.004
    private var config: Config
    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?

    public init(config: Config = Config()) { self.config = config }

    /// Feed one measurement (RMS level, 0…1) taken at `time` seconds. Returns an event when the state changes.
    public mutating func process(level: Float, at time: TimeInterval) -> Event? {
        let loud = level >= max(config.minimumLevel, noiseFloor * config.startRatio)
        let quiet = level < max(config.minimumLevel, noiseFloor * config.stopRatio)
        if !isSpeaking {
            // The floor follows the room while nobody is talking.
            if quiet || !loud { noiseFloor = noiseFloor * 0.95 + level * 0.05 }
            if loud {
                loudSince = loudSince ?? time
                if time - (loudSince ?? time) >= config.attack {
                    isSpeaking = true
                    quietSince = nil
                    return .speechStarted
                }
            } else {
                loudSince = nil
            }
            return nil
        }
        if quiet {
            quietSince = quietSince ?? time
            if time - (quietSince ?? time) >= config.hangover {
                isSpeaking = false
                loudSince = nil
                quietSince = nil
                return .speechEnded
            }
        } else {
            quietSince = nil
        }
        return nil
    }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Matches a wake phrase at the start of an utterance and returns what was asked after it.
public enum WakeWordMatcher {
    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// "Hey Grizzy, what's on my calendar?" → "what's on my calendar?". Nil when the utterance doesn't
    /// start with the phrase. Speech recognisers vary the spelling, so a few spoken forms are accepted.
    public static func command(in transcript: String, phrase: String = "hey grizzy", alternates: [String] = ["hey grizzly", "hey grizzy bot", "hey grizzie"]) -> String? {
        let candidates = ([phrase] + alternates).map(words).sorted { $0.count > $1.count }
        let spoken = words(transcript)
        for wake in candidates where !wake.isEmpty && spoken.count >= wake.count && Array(spoken.prefix(wake.count)) == wake {
            // Cut the original text after the same number of words, keeping its own punctuation and case.
            var count = 0
            var inWord = false
            var cut = transcript.endIndex
            for idx in transcript.indices {
                let alnum = transcript[idx].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                if alnum { inWord = true } else if inWord {
                    inWord = false
                    count += 1
                    if count == wake.count { cut = idx; break }
                }
            }
            var rest = String(transcript[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = rest.first, first.isPunctuation || first.isWhitespace { rest.removeFirst() }
            return rest
        }
        return nil
    }
}

/// What a hands-free listener does with each finished utterance.
public enum HandsFreeGate {
    public enum Outcome: Equatable, Sendable {
        /// Not addressed to the bot: ignored, never stored or sent.
        case ignored
        /// The wake phrase and nothing else: keep listening for the command that follows.
        case awaitingCommand
        case command(String)
    }

    public static func decide(utterance: String, awaiting: Bool, phrase: String = "hey grizzy") -> Outcome {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        if let rest = WakeWordMatcher.command(in: trimmed, phrase: phrase) {
            return rest.isEmpty ? .awaitingCommand : .command(rest)
        }
        return awaiting ? .command(trimmed) : .ignored
    }
}
