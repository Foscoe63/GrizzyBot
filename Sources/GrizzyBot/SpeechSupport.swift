import AVFoundation
import Foundation
import GrizzyBotCore
import Speech
import UserNotifications

@MainActor
enum ReplySpeaker {
    private static let synth = AVSpeechSynthesizer()
    private static var player: AVAudioPlayer?

    static func speak(_ text: String, voiceName: String? = nil, apiKey: String? = nil) {
        let cleaned = text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        let clipped = String(cleaned.prefix(4000))
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            Task { await speakElevenLabs(clipped, apiKey: key, voiceName: voiceName) }
            return
        }
        speakMacOS(clipped, voiceName: voiceName)
    }

    private static func speakMacOS(_ text: String, voiceName: String?) {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceName, !voiceName.isEmpty,
           let match = AVSpeechSynthesisVoice.speechVoices().first(where: {
               $0.name.localizedCaseInsensitiveContains(voiceName)
           }) {
            utterance.voice = match
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.47
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        synth.speak(utterance)
    }

    private static func speakElevenLabs(_ text: String, apiKey: String, voiceName: String?) async {
        do {
            let request = try ElevenLabsTTS.request(text: text, apiKey: apiKey, voiceName: voiceName)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ElevenLabsError.http(http.statusCode, body)
            }
            synth.stopSpeaking(at: .immediate)
            let audio = try AVAudioPlayer(data: data)
            player = audio
            audio.prepareToPlay()
            audio.play()
        } catch {
            speakMacOS(text, voiceName: voiceName)
        }
    }

    static func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
    }
}

@MainActor
enum FinishNotifier {
    static func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(bot: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = bot
        content.body = String(text.prefix(180))
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
@Observable
final class DictationSession {
    var isListening = false
    var transcript = ""
    var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    func start() {
        error = nil
        transcript = ""
        Task {
            let speech = await Self.authorizeSpeech()
            guard speech else {
                error = "Speech recognition was denied."
                return
            }
            let mic = await Self.authorizeMic()
            guard mic else {
                error = "Microphone access was denied."
                return
            }
            begin()
        }
    }

    func stop() -> String {
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        return text
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            self.error = error.localizedDescription
            return
        }
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if error != nil, self?.isListening == true {
                    self?.error = error?.localizedDescription
                    _ = self?.stop()
                }
            }
        }
    }

    private static func authorizeSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func authorizeMic() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
