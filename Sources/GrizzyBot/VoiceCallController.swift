import Foundation
import GrizzyBotCore

/// A live voice call with one bot: it listens, sends what you said once you pause, reads the reply
/// aloud, and asks for approvals out loud. The mic is off while the bot speaks so it never hears itself.
/// Rules (when you've finished, what counts as "allow") live in `VoiceCall`.
@MainActor
@Observable
final class VoiceCallController {
    private(set) var phase: VoiceCall.Phase = .listening
    private(set) var isActive = false
    private(set) var botName = ""
    var transcript: String { dictation.transcript }
    var error: String? { dictation.error }

    private let dictation = DictationSession()
    private var loop: Task<Void, Never>?

    func start(store: AppStore, botId: String) {
        guard !isActive, let bot = store.bots.first(where: { $0.id == botId }) else { return }
        botName = bot.name
        isActive = true
        loop = Task { [weak self] in await self?.run(store: store, botId: botId) }
    }

    func hangUp() {
        loop?.cancel()
        loop = nil
        _ = dictation.stop()
        ReplySpeaker.stop()
        isActive = false
    }

    private func run(store: AppStore, botId: String) async {
        defer { if isActive { hangUp() } }
        while !Task.isCancelled {
            // A bot waiting on an approval is asked about out loud.
            if store.pendingApprovalMessageId(botId: botId) != nil {
                phase = .waitingForApproval
                await say(VoiceCall.approvalPrompt(bot: botName), store: store)
                guard let answer = await listen(store: store, botId: botId) else { return }
                if VoiceCall.isHangUp(answer) { return }
                switch VoiceCall.approvalDecision(answer) {
                case .allow: store.answerPendingApproval(botId: botId, decision: .allow)
                case .alwaysAllow: store.answerPendingApproval(botId: botId, decision: .alwaysAllow)
                case .deny: store.answerPendingApproval(botId: botId, decision: .deny)
                case .unclear: await say("Sorry, I didn't catch that.", store: store)
                }
                await waitUntilSettled(store: store, botId: botId)
                continue
            }
            phase = .listening
            guard let said = await listen(store: store, botId: botId) else { return }
            if VoiceCall.isHangUp(said) { return }
            store.send(botId: botId, text: said)
            phase = .thinking
            await waitUntilSettled(store: store, botId: botId)
            if store.pendingApprovalMessageId(botId: botId) != nil { continue }
            let reply = VoiceCall.spokenText(store.lastReplyText(botId: botId))
            if !reply.isEmpty {
                phase = .speaking
                await say(reply, store: store)
            }
        }
    }

    /// Listens until the person pauses. Returns nil if the call was ended or the mic is unavailable.
    private func listen(store: AppStore, botId: String) async -> String? {
        dictation.start()
        var last = ""
        var changed = Date.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if dictation.error != nil && !dictation.isListening { return nil }
            let now = dictation.transcript
            if now != last { last = now; changed = .now }
            if VoiceCall.utteranceFinished(transcript: now, lastChange: changed) {
                return dictation.stop()
            }
        }
        return nil
    }

    private func say(_ text: String, store: AppStore) async {
        ReplySpeaker.speak(text, voiceName: store.appConfig.ttsVoice, apiKey: store.appConfig.ttsKey)
        try? await Task.sleep(for: .milliseconds(400))
        while ReplySpeaker.isSpeaking, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func waitUntilSettled(store: AppStore, botId: String) async {
        while !Task.isCancelled, store.isRunActive(botId: botId), store.pendingApprovalMessageId(botId: botId) == nil {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
