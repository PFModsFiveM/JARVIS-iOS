import AVFoundation
import Combine
import Foundation

/// JARVIS's answers, spoken on the phone with the best British English voice installed.
/// (Settings › Accessibility › Spoken Content › Voices › English (UK) has the enhanced and premium voices.)
@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onSpeaking: ((Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private lazy var voice: AVSpeechSynthesisVoice? = {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return british.first { $0.quality == .premium }
            ?? british.first { $0.quality == .enhanced }
            ?? british.first { $0.gender == .male }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synthesizer.stopSpeaking(at: .immediate)
        onSpeaking?(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    /// Only the last utterance's ending counts, and only if nothing is being spoken by now.
    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        onSpeaking?(false)
    }
}
