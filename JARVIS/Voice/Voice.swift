import AVFoundation
import Combine
import Foundation

/// JARVIS's answers, spoken on the phone. In JARVIS's own voice when the PC sends it - the same Piper voice you hear
/// at the desk, with the mouth schedule the face speaks by - and otherwise with the best British English voice
/// installed. (Settings › Accessibility › Spoken Content › Voices › English (UK) has the enhanced and premium voices.)
@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var schedule: [MouthFrame] = []
    private var taken = 0
    private var wordAt: Date?
    private var ownSession = false
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

    var isSpeaking: Bool { player?.isPlaying == true || synthesizer.isSpeaking }

    /// Reads the words out in the phone's own voice.
    func say(_ text: String) {
        guard !text.isEmpty else { return }
        stopPlayer()
        prepareSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synthesizer.stopSpeaking(at: .immediate)
        onSpeaking?(true)
        synthesizer.speak(utterance)
    }

    /// Plays JARVIS's own voice from the PC. False if the audio will not play, so the caller can read the words instead.
    @discardableResult
    func play(wav: Data, mouth: [Float]) -> Bool {
        synthesizer.stopSpeaking(at: .immediate)
        stopPlayer()
        prepareSession()

        guard let player = try? AVAudioPlayer(data: wav) else { return false }
        player.delegate = self
        schedule = stride(from: 0, to: mouth.count - 2, by: 3).map { MouthFrame(level: mouth[$0], openness: mouth[$0 + 1], width: mouth[$0 + 2]) }
        taken = 0
        self.player = player
        guard player.play() else { self.player = nil; return false }
        onSpeaking?(true)
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        stopPlayer()
        finished()
    }

    // MARK: what the face reads

    /// The mouth frames that became audible since the last call - the PC's `LipSyncFeed.Take`, clocked by the
    /// player rather than by a playback reference. Nil when JARVIS's own voice is not playing.
    func takeMouth() -> [MouthFrame]? {
        guard let player, player.isPlaying, !schedule.isEmpty else { return nil }
        let heard = min(schedule.count, Int(player.currentTime / Double(FaceAnimator.hopSeconds)) + 1)
        guard heard > taken else { return [] }
        let frames = Array(schedule[taken..<heard])
        taken = heard
        return frames
    }

    /// How loud JARVIS is right now, 0-1: from the schedule while its own voice plays, from each word as the
    /// phone's voice reaches it otherwise.
    var level: Float {
        if let player, player.isPlaying, !schedule.isEmpty {
            let index = min(schedule.count - 1, max(0, Int(player.currentTime / Double(FaceAnimator.hopSeconds))))
            return schedule[index].level
        }
        if synthesizer.isSpeaking, let wordAt {
            return Float(0.85 * exp(-Date().timeIntervalSince(wordAt) / 0.14))
        }
        return 0
    }

    // MARK: session

    /// Speech is audible with the ring switch on silent, and ducks music. Left alone while the wake word holds the
    /// session for recording: its category already plays through the speaker.
    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            ownSession = true
        } catch {
            ownSession = false
        }
    }

    private func releaseSession() {
        guard ownSession, !isSpeaking else { return }
        ownSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopPlayer() {
        player?.stop()
        player = nil
        schedule = []
        taken = 0
    }

    // MARK: delegates

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.wordAt = Date() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stopPlayer() }
            self.finished()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if self.player === player { self.stopPlayer() }
            self.finished()
        }
    }

    /// Only the last ending counts, and only if nothing is being spoken by now.
    private func finished() {
        guard !isSpeaking else { return }
        wordAt = nil
        onSpeaking?(false)
        releaseSession()
    }
}
