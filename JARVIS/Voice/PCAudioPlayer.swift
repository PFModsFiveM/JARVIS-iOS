import AVFoundation
import Foundation

/// Plays the PC's sound as it arrives: 16-bit mono PCM pieces scheduled back to back on an audio engine, with a small
/// cushion so a late piece does not click. A piece that arrives after the cushion has run dry starts a new one.
@MainActor
final class PCAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queued = 0
    private var running = false

    /// About 300 ms held back before playing starts: Wi-Fi jitter, not latency anyone notices on a live stream.
    private let cushion = 3

    func start(rate: Double) {
        guard !running, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        self.format = format

        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            running = true
            queued = 0
        } catch {
            running = false
        }
    }

    func play(_ pcm: Data) {
        guard running, let format, pcm.count >= 2 else { return }
        let frames = pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }

        queued += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.queued -= 1 }
        }
        if !node.isPlaying && queued >= cushion { node.play() }
    }

    func stop() {
        guard running else { return }
        running = false
        node.stop()
        engine.stop()
        engine.detach(node)
        queued = 0
    }
}
