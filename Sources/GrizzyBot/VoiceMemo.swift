import AVFoundation
import AppKit
import GrizzyBotCore
import Observation
import SwiftUI

/// Reads a reply aloud with the system voice and tells the view which word is being spoken, so the
/// transcript can highlight it and a tap on any word can start from there.
@MainActor
@Observable
final class VoiceMemo {
    static let shared = VoiceMemo()

    private(set) var playingMessageId: String?
    private(set) var text = ""
    private(set) var words: [VoiceTranscript.Word] = []
    private(set) var currentWord: Int?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = Delegate()
    /// Where in `text` the current utterance started (it restarts when you tap a word).
    @ObservationIgnored private var baseOffset = 0

    private init() {
        synth.delegate = delegate
        delegate.owner = self
    }

    func isPlaying(_ messageId: String) -> Bool { playingMessageId == messageId }

    func toggle(messageId: String, markdown: String, voiceName: String?) {
        if playingMessageId == messageId { stop(); return }
        start(messageId: messageId, markdown: markdown, voiceName: voiceName, from: 0)
    }

    func start(messageId: String, markdown: String, voiceName: String?, from offset: Int) {
        ReplySpeaker.stop()
        synth.stopSpeaking(at: .immediate)
        if playingMessageId != messageId {
            text = String(VoiceTranscript.plainText(fromMarkdown: markdown).prefix(4_000))
            words = VoiceTranscript.words(in: text)
        }
        playingMessageId = messageId
        baseOffset = offset
        currentWord = VoiceTranscript.wordIndex(at: offset, in: words)
        let utterance = AVSpeechUtterance(string: VoiceTranscript.suffix(of: text, from: offset))
        if let voiceName, !voiceName.isEmpty,
           let match = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name.localizedCaseInsensitiveContains(voiceName) }) {
            utterance.voice = match
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.47
        pendingVoice = voiceName
        synth.speak(utterance)
    }

    @ObservationIgnored private var pendingVoice: String?

    func seek(toWord index: Int) {
        guard let id = playingMessageId, words.indices.contains(index) else { return }
        // `start` keeps the cached words when the message is unchanged.
        start(messageId: id, markdown: text, voiceName: pendingVoice, from: words[index].offset)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        playingMessageId = nil
        currentWord = nil
    }

    fileprivate func spoke(range: NSRange) {
        currentWord = VoiceTranscript.wordIndex(at: baseOffset + range.location, in: words)
    }

    fileprivate func finished() {
        // A restart (tap on a word) cancels the old utterance; only a natural end clears the state.
        if !synth.isSpeaking { stop() }
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: VoiceMemo?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.spoke(range: characterRange) }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.owner?.finished() }
        }
    }
}

/// The reply shown as plain text while it is read: the spoken word is highlighted, any word can be tapped.
struct VoiceTranscriptView: View {
    let memo: VoiceMemo
    let messageId: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 15.5))
            .lineSpacing(15.5 * 0.45)
            .foregroundStyle(Theme.textPrimary)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "grizzy-seek", let host = url.host, let index = Int(host) {
                    memo.seek(toWord: index)
                    return .handled
                }
                return .systemAction
            })
            .textSelection(.disabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let ns = memo.text as NSString
        var cursor = 0
        for (index, word) in memo.words.enumerated() {
            if word.offset > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: word.offset - cursor)))
            }
            var piece = AttributedString(ns.substring(with: NSRange(location: word.offset, length: word.length)))
            piece.link = URL(string: "grizzy-seek://\(index)")
            piece.underlineStyle = nil
            piece.foregroundColor = Theme.textPrimary
            if memo.currentWord == index {
                piece.backgroundColor = Theme.orange.opacity(0.35)
            }
            result += piece
            cursor = word.end
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }
}
