import Foundation

/// Which path a spoken answer takes - programme §4A.
///
/// Ordered best to worst, and the order is about *whose voice it is* rather than about latency.
/// JARVIS has one voice and the owner knows it; a generic British system voice answering in its
/// place is not a degraded version of JARVIS, it is a different assistant, and being surprised by
/// that is worse than reading the words.
enum VoiceRoute: Equatable {
    /// A sentence JARVIS has said before, rendered in its own voice and kept.
    ///
    /// The first rung in practice as well as in theory: the phrase bank is warmed from the PC, so
    /// the handful of things JARVIS says constantly are in its own voice with the desk switched
    /// off and no network at all.
    case cached(String)

    /// Synthesised on this phone, in JARVIS's own voice. Not available - see `MobileVoiceRouter`.
    case onDevice

    /// Rendered by the PC and streamed here. Needs the PC awake.
    case fromThePC

    /// The phone's own British voice, and only when the owner has explicitly allowed it.
    case systemVoice

    /// Nothing will be spoken. The words are still shown.
    case text(String)

    var spoken: Bool {
        switch self {
        case .text: return false
        default: return true
        }
    }
}

/// What JARVIS is saying, as a kind rather than as a string - programme §4B.
///
/// The phrase bank is keyed by this and never by matching the text of an answer. Substring
/// matching an answer to find its audio is the kind of thing that works until somebody rewords a
/// sentence, and then silently stops - and a voice that silently stops being JARVIS's is precisely
/// the failure this whole ladder exists to prevent.
enum SpokenKind: String, CaseIterable, Codable {
    // Acknowledgements, which are most of what JARVIS says.
    case certainly
    case ofCourse
    case rightAway
    case oneMoment

    // Smart home.
    case switchedOn
    case switchedOff
    case commandSent
    case cannotConfirm
    case cannotReach

    // The PC.
    case wakeSent
    case pcWaking
    case pcOnline
    case pcOffline
    case windowsLocked
    case desktopOnline

    // Where the owner is.
    case atHome
    case atUniversity
    case locationUnknown
    case locationStale

    // Power.
    case headsetLow

    // What this phone says for itself when the desk is asleep - priority §14.
    //
    // Added because these are the sentences priority §3 made the phone answer on its own, and the
    // moment JARVIS answers for itself is exactly the moment the PC cannot render for it. A
    // pleasantry read out in the phone's own British voice is a different assistant saying hello.
    case hereAndListening
    case greeting
    case howIAm
    case thanks
    case goodbye
    case nothingWantsAttention
    case houseUnreachable
    case noSuchDevice
    case nothingReadable

    /// The words, so the bank can be warmed by asking the PC to render exactly these.
    ///
    /// Where a sentence has an owner elsewhere it is read from there; the rest are written here.
    /// Either way there is one copy, because what is rendered has to be byte-identical to what is
    /// later looked up and two lists would drift. Anything with a value in it - a battery
    /// percentage, a device name - is deliberately absent: it cannot be pre-rendered, and
    /// pretending otherwise would put a stale number in JARVIS's own voice. `SpokenPhrase` now
    /// enforces that against every sentence the cache is offered, not just against this list.
    var words: String {
        switch self {
        case .certainly: return "Certainly, sir."
        case .ofCourse: return "Of course, sir."
        case .rightAway: return "Right away, sir."
        case .oneMoment: return "One moment, sir."
        case .switchedOn: return "That's on, sir."
        case .switchedOff: return "That's off, sir."
        case .commandSent: return "I've sent the command, sir."
        case .cannotConfirm: return "I couldn't confirm the state, sir."
        case .cannotReach: return "I can't reach it at the moment, sir."
        case .wakeSent: return "Wake request sent, sir."
        case .pcWaking: return "Your PC is waking up, sir."
        case .pcOnline: return "Your PC is online, sir."
        case .pcOffline: return "Your PC is offline, sir."
        case .windowsLocked: return "Windows is locked, sir."
        case .desktopOnline: return "Desktop JARVIS is online."
        case .atHome: return "You're at home, sir."
        case .atUniversity: return "You're at university, sir."
        case .locationUnknown: return "I can't confirm your current location, sir."
        case .locationStale: return "Your last known location is out of date, sir."
        case .headsetLow: return "Your headset is running low, sir."

        // Taken from MobilePhrases rather than written out again. The rule above - what is
        // rendered has to be byte-identical to what is looked up - is why there is one list, and
        // these sentences already have an owner.
        case .hereAndListening: return MobilePhrases.hereAndListening()
        case .greeting: return MobilePhrases.greeting()
        case .howIAm: return MobilePhrases.howIAm()
        case .thanks: return MobilePhrases.welcome()
        case .goodbye: return MobilePhrases.untilLater()
        case .nothingWantsAttention: return MobilePhrases.nothingWantsAttention()
        case .houseUnreachable: return MobilePhrases.houseUnreachable()
        case .noSuchDevice: return MobilePhrases.noSuchDevice()
        case .nothingReadable: return MobilePhrases.nothingReadable()
        }
    }
}

/// The one authority on how a spoken answer is produced - programme §4A.
///
/// **Not a second player.** `Voice` plays audio and speaks text and goes on being the only thing
/// that does; this decides which of those it is asked to do, and with what. The split matters
/// because the decision is the part with a rule in it and the playing is the part with AVFoundation
/// in it, and only one of those can be tested.
enum MobileVoiceRouter {
    /// What this phone can do at the moment, as plain values.
    struct Able {
        /// A cached rendering of exactly these words, if there is one.
        let cached: String?

        /// Whether a JARVIS voice model is installed here and a runtime can speak with it.
        let onDevice: Bool

        /// Whether the PC is awake and can render.
        let pcAnswering: Bool

        /// Whether the owner has explicitly allowed the phone's own voice to stand in.
        let systemVoiceAllowed: Bool

        /// Whether anything should be spoken at all right now.
        let speaking: Bool

        init(
            cached: String? = nil,
            onDevice: Bool = false,
            pcAnswering: Bool = false,
            systemVoiceAllowed: Bool = false,
            speaking: Bool = true
        ) {
            self.cached = cached
            self.onDevice = onDevice
            self.pcAnswering = pcAnswering
            self.systemVoiceAllowed = systemVoiceAllowed
            self.speaking = speaking
        }
    }

    /// Why on-device synthesis is never chosen yet.
    ///
    /// The PC will hand this phone the voice model - `voice.model` and `voice.model.chunk` have
    /// been on the bridge since it was written, with the Piper config and a checksum. What is
    /// missing is a runtime: Piper is a C++ program around onnxruntime and espeak-ng, and nothing
    /// on iOS speaks that model without one being built and shipped inside the app. That is a
    /// real piece of work and not a line of wiring, so the rung exists, is routed around, and
    /// says why rather than pretending.
    static let whyNotOnDevice =
        "The voice model transfers, but nothing on the phone can speak it yet: Piper needs "
        + "onnxruntime and espeak-ng compiled into the app. Until then JARVIS's own voice on the "
        + "phone comes from the cache and from the PC."

    /// Which route a sentence takes.
    static func route(_ text: String, able: Able) -> VoiceRoute {
        guard able.speaking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .text(text)
        }

        if let cached = able.cached { return .cached(cached) }
        if able.onDevice { return .onDevice }
        if able.pcAnswering { return .fromThePC }

        // The rung that is off by default, and the reason this type exists. With nothing above it
        // available, a system voice would be a different assistant answering in JARVIS's place -
        // so unless the owner has said they would rather that than silence, the words are shown.
        if able.systemVoiceAllowed { return .systemVoice }

        return .text(text)
    }

    /// Why a route was chosen, for the owner reading a settings page rather than for a log.
    static func because(_ route: VoiceRoute, able: Able) -> String {
        switch route {
        case .cached:
            return "In JARVIS's own voice, from a sentence already rendered."

        case .onDevice:
            return "Spoken on this phone in JARVIS's own voice."

        case .fromThePC:
            return "Rendered by your PC in JARVIS's own voice."

        case .systemVoice:
            return "In the phone's own British voice, which you have allowed."

        case .text:
            if !able.speaking { return "Not spoken - speaking is off." }

            return able.systemVoiceAllowed
                ? "Shown rather than spoken - nothing can speak it just now."
                : "Shown rather than spoken. JARVIS's voice isn't available and the phone's own "
                    + "voice is off, so you won't be surprised by a different one."
        }
    }
}
