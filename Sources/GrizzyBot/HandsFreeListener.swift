import AVFoundation
import GrizzyBotCore
import Speech
import SwiftUI

/// Listens for the wake phrase ("Hey Grizzy") and hands the command that follows to the chat. Audio is
/// only sent to speech recognition while someone is actually talking (voice activity detection), nothing
/// is kept, and an utterance that doesn't start with the phrase is dropped.
@MainActor
@Observable
final class HandsFreeListener {
    var isOn = false
    var status = ""
    var error: String?

    var onCommand: ((String) -> Void)?
    static let phraseKey = "handsFreePhrase"
    static let defaultPhrase = "hey grizzy"
    var phrase: String {
        let saved = UserDefaults.standard.string(forKey: Self.phraseKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return saved.isEmpty ? Self.defaultPhrase : saved
    }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var vad = VoiceActivityDetector()
    private var awaitingCommand = false
    private var latest = ""
    private var started: Date = .now

    func toggle() { isOn ? stop() : start() }

    func start() {
        error = nil
        Task {
            guard await Self.speechAllowed() else { error = "Speech recognition was denied."; return }
            guard await Self.micAllowed() else { error = "Microphone access was denied."; return }
            guard let recognizer, recognizer.isAvailable else { error = "Speech recognition is not available."; return }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            vad = VoiceActivityDetector()
            started = .now
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let level: Float = buffer.floatChannelData.map { VoiceActivityDetector.rms(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength))) } ?? 0
                Task { @MainActor in self.handle(buffer: buffer, level: level) }
            }
            do { try engine.start() } catch { self.error = error.localizedDescription; return }
            isOn = true
            status = "Listening for “\(phrase)”"
        }
    }

    func stop() {
        isOn = false
        status = ""
        awaitingCommand = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        endUtterance(deliver: false)
    }

    private func handle(buffer: AVAudioPCMBuffer, level: Float) {
        guard isOn else { return }
        let event = vad.process(level: level, at: Date().timeIntervalSince(started))
        if event == .speechStarted { beginUtterance() }
        request?.append(buffer)
        if event == .speechEnded { endUtterance(deliver: true) }
    }

    private func beginUtterance() {
        guard request == nil, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        latest = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.latest = text }
        }
    }

    private func endUtterance(deliver: Bool) {
        request?.endAudio()
        request = nil
        let task = self.task
        self.task = nil
        guard deliver else { task?.cancel(); return }
        // Give the recogniser a moment to settle its final words before judging the utterance.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            task?.finish()
            let text = latest
            latest = ""
            switch HandsFreeGate.decide(utterance: text, awaiting: awaitingCommand, phrase: phrase) {
            case .ignored: awaitingCommand = false; status = "Listening for “\(phrase)”"
            case .awaitingCommand: awaitingCommand = true; status = "Yes? Say what you need."
            case .command(let command):
                awaitingCommand = false
                status = "Listening for “\(phrase)”"
                onCommand?(command)
            }
        }
    }

    private static func speechAllowed() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    private static func micAllowed() async -> Bool {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
    }
}
