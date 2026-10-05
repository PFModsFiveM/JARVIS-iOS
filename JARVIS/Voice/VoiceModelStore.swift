import CryptoKit
import Foundation

/// What of JARVIS's own voice has actually reached this phone - priority §9C.
///
/// **It reports; it does not download.** The PC offers the model through `voice.model` and
/// `voice.model.chunk`, and this app has never asked for them - so on a real phone today every
/// answer here is "not present", and that is the truth rather than a gap in the reporting. The
/// reason not to implement the download yet is one layer further down: Piper is C++ around
/// onnxruntime and espeak-ng, neither is compiled into the app, and a 60 MB model sitting on the
/// owner's phone that nothing can speak is worse than no model.
///
/// So this exists to say exactly where the chain stops, which is the thing the owner's question
/// actually needs. When the runtime arrives, the download goes here and nothing else changes.
@MainActor
final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()

    /// What the PC said the model's bytes should hash to, when it offered one.
    @Published private(set) var expected: String?

    private let folder: URL?

    nonisolated init(folder: URL? = VoiceModelStore.defaultFolder()) {
        self.folder = folder
    }

    private var model: URL? { folder?.appendingPathComponent("jarvis.onnx") }
    private var config: URL? { folder?.appendingPathComponent("jarvis.onnx.json") }

    /// Whether the model's bytes are here.
    var modelPresent: Bool {
        guard let model else { return false }
        return FileManager.default.fileExists(atPath: model.path)
    }

    /// Whether its configuration came with it. A model without one cannot be loaded at all.
    var configPresent: Bool {
        guard let config else { return false }
        return FileManager.default.fileExists(atPath: config.path)
    }

    /// How big what arrived is, for the diagnostic.
    var bytes: Int {
        guard let model, let values = try? model.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return values.fileSize ?? 0
    }

    /// Whether what is here matches what the PC said it sent.
    ///
    /// False when there is nothing to check, deliberately: "the checksum is fine" about a file
    /// that does not exist is the kind of true-but-useless answer that makes a diagnostic
    /// worthless. A missing model fails this, and the rung above says which of the two it was.
    var checksumValid: Bool {
        guard let model, let expected, modelPresent else { return false }
        guard let data = try? Data(contentsOf: model) else { return false }

        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        return actual.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// Records what the PC says the model should hash to.
    func expects(_ checksum: String?) {
        expected = checksum?.isEmpty == true ? nil : checksum
    }

    /// Where the chain stops, in one sentence, for the report and for the owner.
    var blocker: String {
        if !modelPresent {
            return "The model has never been asked for. This app does not request it yet, because "
                + "nothing in it could run the model if it arrived."
        }

        if !configPresent { return "The model is here; its configuration is not." }
        if !checksumValid { return "What is here does not match the checksum the PC sent." }

        return "The model is here and complete. No runtime in this app can speak it yet."
    }

    nonisolated private static func defaultFolder() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }

        return support.appendingPathComponent("voice", isDirectory: true)
    }
}
