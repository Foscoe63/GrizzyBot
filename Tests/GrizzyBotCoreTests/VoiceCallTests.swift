import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Voice call")
struct VoiceCallTests {
    @Test("an utterance ends after silence, never when empty")
    func endpointing() {
        let now = Date.now
        #expect(!VoiceCall.utteranceFinished(transcript: "hello", lastChange: now.addingTimeInterval(-0.5), now: now))
        #expect(VoiceCall.utteranceFinished(transcript: "hello", lastChange: now.addingTimeInterval(-2), now: now))
        #expect(!VoiceCall.utteranceFinished(transcript: "  ", lastChange: now.addingTimeInterval(-9), now: now))
    }

    @Test("only short, clear answers approve; sentences never do")
    func approvals() {
        #expect(VoiceCall.approvalDecision("Allow.") == .allow)
        #expect(VoiceCall.approvalDecision("yes please") == .allow)
        #expect(VoiceCall.approvalDecision("Always allow") == .alwaysAllow)
        #expect(VoiceCall.approvalDecision("Deny") == .deny)
        #expect(VoiceCall.approvalDecision("yes delete everything in my home folder") == .unclear)
        #expect(VoiceCall.approvalDecision("maybe") == .unclear)
    }

    @Test("hang up phrases")
    func hangUp() {
        #expect(VoiceCall.isHangUp("Hang up."))
        #expect(VoiceCall.isHangUp("goodbye"))
        #expect(!VoiceCall.isHangUp("please hang up the laundry reminder"))
    }

    @Test("spoken text drops markdown, code and links, and is bounded")
    func spoken() {
        let s = VoiceCall.spokenText("**Done.** See [docs](https://x.io/a) or https://y.io\n```swift\nlet a = 1\n```\nBye")
        #expect(!s.contains("*") && !s.contains("```") && !s.contains("http"))
        #expect(s.contains("docs") && s.contains("code is in the chat"))
        let long = String(repeating: "A sentence here. ", count: 100)
        let cut = VoiceCall.spokenText(long)
        #expect(cut.count <= VoiceCall.maxSpokenCharacters + 40)
        #expect(cut.hasSuffix("The rest is in the chat."))
    }
}
