import Foundation

/// Why a rung of the voice ladder is or is not available - priority §9C.
///
/// The question this answers is the one the owner actually has: JARVIS is speaking in a voice that
/// is not its own, or not speaking at all, and they want to know which part is missing. Before
/// this the answer was somewhere between a log line and a guess.
struct VoiceDiagnosis: Equatable {
    /// Whether JARVIS's own model has been transferred to this phone.
    let modelPresent: Bool

    /// Whether its configuration came with it. A model without one cannot be loaded.
    let configPresent: Bool

    /// Whether the bytes match the checksum the PC sent.
    let checksumValid: Bool

    /// Whether anything on this phone could run the model if it were here.
    ///
    /// Always false today, and that is the honest answer rather than a missing feature: Piper is
    /// C++ around onnxruntime and espeak-ng, and neither is compiled into the app. The model
    /// transfers, and nothing can speak it.
    let runtimeAvailable: Bool

    /// How many of JARVIS's phrases are cached, and how much room they take.
    let cachedPhrases: Int
    let cachedBytes: Int

    /// The last phrase the PC rendered for this phone, for the owner to recognise.
    let lastRendered: String?

    /// Whether the owner has allowed the phone's own voice as a last resort.
    let systemVoiceAllowed: Bool

    /// Which rung would actually be used for a phrase that is not cached.
    let route: VoiceRoute

    /// The rungs, each with whether it is available and why not.
    var rungs: [(rung: String, available: Bool, because: String)] {
        [
            ("Cached phrases",
             cachedPhrases > 0,
             cachedPhrases > 0
                ? "\(cachedPhrases) phrases, \(cachedBytes / 1024) kB, in JARVIS's own voice"
                : "nothing cached yet; phrases arrive as your PC renders them"),

            ("JARVIS's voice on this phone",
             modelPresent && configPresent && checksumValid && runtimeAvailable,
             !modelPresent ? "the model hasn't been transferred from your PC"
                : !configPresent ? "the model is here but its configuration isn't"
                : !checksumValid ? "the transferred model doesn't match its checksum"
                : !runtimeAvailable ? "the model is here and complete; nothing on this phone can run it yet"
                : "ready"),

            ("Your PC speaking",
             route == .fromThePC,
             route == .fromThePC ? "your PC is reachable and will render it"
                : "your PC isn't reachable"),

            ("This phone's own voice",
             systemVoiceAllowed,
             systemVoiceAllowed
                ? "allowed, and used only when nothing above it is"
                : "off, so I show words rather than speak in a voice that isn't mine"),

            ("Words on screen", true, "always available")
        ]
    }

    /// One line saying what will happen next time JARVIS has something to say.
    var summary: String {
        switch route {
        case .cached: return "I'll use a phrase I already have, in my own voice."
        case .onDevice: return "I'll speak it on this phone, in my own voice."
        case .fromThePC: return "I'll ask your PC to say it in my voice."
        case .systemVoice: return "I'll use this phone's voice, because nothing above it is available."
        case .text: return "I'll show the words rather than speak in a voice that isn't mine."
        }
    }

    /// Why JARVIS's own voice is not being synthesised here, in one sentence.
    ///
    /// Said rather than implied, because "it's using the wrong voice" is a complaint and "the
    /// runtime isn't in the app yet" is an explanation.
    var ownVoiceBlocker: String? {
        if !modelPresent { return "The model hasn't reached this phone." }
        if !configPresent { return "The model is here; its configuration isn't." }
        if !checksumValid { return "The model doesn't match the checksum your PC sent." }
        if !runtimeAvailable { return "The model is here and complete. Nothing in this app can run it yet." }

        return nil
    }
}
