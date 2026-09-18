import AVFoundation
import Combine
import Foundation
import Speech

/// "Jarvis, …" on the phone: listens continuously with on-device speech recognition, and when it hears the name,
/// takes the rest of the sentence as a request once the speaker pauses.
///
/// Nothing leaves the phone until a request is recognised: recognition runs on the device
/// (`requiresOnDeviceRecognition`) and only the words after "Jarvis" are sent - to your PC, not to anyone else.
///
/// Background: with the `audio` background mode the listener keeps running when the app is not on screen or the
/// phone is locked, for as long as the audio session is active; iOS shows the microphone indicator while it does.
/// Apple's recognizer ends a task after about a minute, so the listener starts a fresh one before that.
@MainActor
final class WakeListener: ObservableObject {
    enum Phase: Equatable { case off, waiting, hearing(String) }

    enum Failure: LocalizedError {
        case speechDenied, microphoneDenied, unavailable

        var errorDescription: String? {
            switch self {
            case .speechDenied: return "Speech recognition is off for JARVIS. Turn it on in Settings › JARVIS."
            case .microphoneDenied: return "The microphone is off for JARVIS. Turn it on in Settings › JARVIS."
            case .unavailable: return "This iPhone has no on-device English speech model yet. Turn on Siri or Dictation in English (Settings › Keyboard › Dictation), let it download over Wi-Fi, then try again."
            }
        }
    }

    @Published private(set) var phase: Phase = .off {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }

    /// The model mirrors this, so views watch one object rather than two.
    var onPhase: ((Phase) -> Void)?

    /// Set while JARVIS is speaking, so it never hears itself.
    var paused = false {
        didSet {
            guard paused != oldValue, running else { return }
            if paused { endTask() } else { restartSoon() }
        }
    }

    var onCommand: ((String) -> Void)?
    var running: Bool { phase != .off }

    private let wakeWords = ["jarvis", "jarvus", "jervis"]
    private var recognizer: SFSpeechRecognizer?

    /// The first English recognizer that can run on this iPhone without the network. en-GB was fixed before,
    /// and a phone without the British model then had no wake word at all even with another English one installed.
    private static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        var identifiers = ["en-GB", Locale.current.identifier, "en-US"]
        identifiers += SFSpeechRecognizer.supportedLocales().map(\.identifier).filter { $0.hasPrefix("en") }.sorted()
        var tried = Set<String>()
        for identifier in identifiers where tried.insert(identifier).inserted {
            if let candidate = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               candidate.isAvailable, candidate.supportsOnDeviceRecognition {
                return candidate
            }
        }
        return nil
    }
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var silence: Timer?
    private var recycle: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() async throws {
        guard !running else { return }

        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw Failure.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        guard let chosen = Self.onDeviceRecognizer() else { throw Failure.unavailable }
        recognizer = chosen

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            // The audio thread: hand the buffer to whichever request is current.
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        observe()
        phase = .waiting
        beginTask()
    }

    func stop() {
        phase = .off
        endTask()
        silence?.invalidate()
        recycle?.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: recognition

    nonisolated(unsafe) private let bufferLock = NSLock()
    nonisolated(unsafe) private var currentRequest: SFSpeechAudioBufferRecognitionRequest?

    nonisolated(unsafe) private var heardLevel: Float = 0

    /// How loud the microphone is, 0-1, for the circle and the face while they listen. Never sent anywhere.
    nonisolated var level: Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return heardLevel
    }

    nonisolated private func append(_ buffer: AVAudioPCMBuffer) {
        var loudness: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            // Speech sits around 0.02-0.15 RMS on the phone's microphone; six times that fills the scale.
            loudness = min(1, (sum / Float(buffer.frameLength)).squareRoot() * 6)
        }

        bufferLock.lock()
        let request = currentRequest
        heardLevel = loudness
        bufferLock.unlock()
        request?.append(buffer)
    }

    private func beginTask() {
        guard running, !paused, let recognizer else { return }
        endTask()

        generation += 1
        let mine = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = ["Jarvis"]
        self.request = request
        bufferLock.lock(); currentRequest = request; bufferLock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                if let result { self.heard(result.bestTranscription.formattedString, final: result.isFinal) }
                if error != nil || result?.isFinal == true { self.restartSoon() }
            }
        }

        // Apple ends a recognition task after about a minute; start a fresh one first while nobody is talking.
        recycle?.invalidate()
        recycle = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .waiting else { return }
                self.beginTask()
            }
        }
        phase = .waiting
    }

    private func endTask() {
        bufferLock.lock(); currentRequest = nil; bufferLock.unlock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func restartSoon() {
        guard running, !paused else { return }
        let mine = generation
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.beginTask()
            }
        }
    }

    // MARK: hold to talk

    private var holding = false
    private var startedForHold = false
    private var holdCommitted = ""
    private var holdTranscript = ""

    /// Everything said while the button is held is the request - no "Jarvis" needed. Starts the microphone for the
    /// hold if the wake word is off, and stops it again afterwards.
    func beginHold() async throws {
        if !running {
            try await start()
            startedForHold = true
        }
        paused = false
        silence?.invalidate()
        holding = true
        holdCommitted = ""
        holdTranscript = ""
        beginTask()
        phase = .hearing("")
    }

    /// The button is up: the last words get a moment to arrive, then the request goes.
    func endHold() {
        guard holding else { return }
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.holding else { return }
                let command = (self.holdCommitted + self.holdTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
                self.holding = false
                self.holdCommitted = ""
                self.holdTranscript = ""
                if self.startedForHold {
                    self.startedForHold = false
                    self.stop()
                } else {
                    self.phase = .waiting
                    self.beginTask()
                }
                if !command.isEmpty { self.onCommand?(command) }
            }
        }
    }

    private func heard(_ transcript: String, final: Bool) {
        if holding {
            // A final result ends that recognition task; what it heard is kept and the next task carries on.
            if final {
                holdCommitted += transcript + " "
                holdTranscript = ""
            } else {
                holdTranscript = transcript
            }
            phase = .hearing(holdCommitted + holdTranscript)
            return
        }

        let lower = transcript.lowercased()
        guard let wake = wakeWords.compactMap({ lower.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }) else {
            return
        }

        // The range is in the lowercased copy; carry it across by character count, not by index.
        let command = String(transcript.dropFirst(lower.distance(from: lower.startIndex, to: wake.upperBound)))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        phase = .hearing(command)

        // The request ends when the speaker pauses: 1.2 s after the last new word, or at once when the recognizer says it is final.
        silence?.invalidate()
        if final {
            finish(command)
        } else {
            silence = Timer.scheduledTimer(withTimeInterval: command.isEmpty ? 5 : 1.2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish(command) }
            }
        }
    }

    private func finish(_ command: String) {
        silence?.invalidate()
        guard case .hearing = phase else { return }
        phase = .waiting
        beginTask()   // a fresh transcript, so the same "Jarvis" is not heard twice
        if !command.isEmpty {
            onCommand?(command)
        }
    }

    // MARK: interruptions

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self, self.running else { return }
                if type == .ended {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.engine.start()
                    self.beginTask()
                } else {
                    self.endTask()
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A headset plugged in or out: the input format changed, so start the engine again.
            Task { @MainActor in
                guard let self, self.running else { return }
                self.stop()
                try? await self.start()
            }
        })
    }
}
