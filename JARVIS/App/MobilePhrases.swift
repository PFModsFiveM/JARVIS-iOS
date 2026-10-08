import Foundation

/// Everything Mobile JARVIS says in its own words - programme §11.
///
/// **Why this exists.** Almost everything the app says comes from the PC, which is right: JARVIS
/// lives there and it is JARVIS speaking. But a handful of answers are this phone's own - the ones
/// about a PC that is off, which is precisely when the PC cannot supply the words - and those had
/// grown wherever they were needed. The result was a register that drifted: "I can only wake
/// DOM-PC from home, sir" next to "I don't know a device by that name.", and "That is not a card
/// address." with nobody addressed at all. One node of JARVIS does not speak in three voices.
///
/// **This is not the voice work.** The PC generates the audio and hands it over, and that stays
/// where it is; this is the *wording*, which the PC cannot supply for a sentence it was never
/// asked. The two are the same JARVIS from different directions.
///
/// **The register, which the tests enforce.** The owner is addressed. Nothing claims an action
/// succeeded unless something confirmed it - a request sent to a vendor the PC cannot reach is
/// "sent", never "done". No technical failure reaches the owner as one: a socket that refused a
/// connection is a machine that is not answering. And nothing is invented: where a number was not
/// measured, the sentence says so rather than supplying one.
enum MobilePhrases {

    // MARK: Waking the PC

    static func wakingIsOff(_ machine: String) -> String {
        "Waking \(machine) is switched off, sir."
    }

    static func cardUnknown(_ machine: String) -> String {
        "I don't know \(machine)'s network card yet, sir. Connect to it once at home and it will tell me."
    }

    static func onlyFromHome(_ machine: String) -> String {
        "I can only wake \(machine) from home, sir - there's no way in from outside set up yet."
    }

    /// Sent, not woken. The protocol has no reply and UDP is not acknowledged, so the machine
    /// being awake is established by it answering and by nothing else.
    static func sendingWake(_ machine: String) -> String {
        "Sending the wake request now, sir. I'll connect as soon as \(machine) answers."
    }

    static func notACardAddress() -> String {
        "That isn't a card address, sir - six pairs of hex digits, like 04-7C-16-4E-A7-F5."
    }

    // MARK: When the request belongs to the PC

    static func thePCsAndItCanBeWoken(_ machine: String) -> String {
        "That one is \(machine)'s, sir, and it isn't answering. Say \u{201C}wake my PC\u{201D} and I'll switch it on, then ask me again."
    }

    static func thePCsAndItCannotBeWoken(_ machine: String) -> String {
        "That one is \(machine)'s, sir, and it isn't answering. I can tell you what it's doing, but waking it isn't set up from here yet."
    }

    static func thePCsAndNothingCanBeDone(_ machine: String) -> String {
        "That one is \(machine)'s, sir, and it isn't answering. There's nothing I can do about it from this phone until waking it is set up."
    }

    // MARK: Being spoken to, with nothing at the desk - priority §3C

    /// A greeting answered rather than forwarded.
    ///
    /// Said by this phone only when the PC is not answering. With the desk awake the PC says it,
    /// because the PC knows what it has been doing and this does not, and a phone that grabbed
    /// "how are you" would be answering for a JARVIS it cannot see.
    static func hereAndListening() -> String {
        "I'm here, sir."
    }

    static func greeting() -> String {
        "Good to hear from you, sir."
    }

    /// How JARVIS is, with the desk asleep. Honest about which part of itself is missing.
    static func howIAmWithoutThePC(_ machine: String) -> String {
        "Running well on this phone, sir. \(machine) isn't answering, so everything at the desk is out of reach for the moment."
    }

    static func howIAm() -> String {
        "Running well, sir."
    }

    static func welcome() -> String {
        "A pleasure, sir."
    }

    static func untilLater() -> String {
        "Until later, sir."
    }

    /// The answer to one pleasantry, which depends on whether the desk is there.
    ///
    /// One function rather than a switch in the app and another in the Siri path, so "hello"
    /// typed, spoken and asked through Siri are the same JARVIS saying the same thing.
    static func pleasantry(
        _ kind: LocalCapability.Pleasantry, pcName: String, pcAnswering: Bool
    ) -> String {
        switch kind {
        case .greeting: return greeting()
        case .thanks: return welcome()
        case .goodbye: return untilLater()
        case .areYouThere: return hereAndListening()
        case .howAreYou: return pcAnswering ? howIAm() : howIAmWithoutThePC(pcName)
        }
    }

    // MARK: Getting the desk ready - priority §4

    /// The wake has been sent and the rest is waiting for the machine to answer.
    ///
    /// Two facts in one sentence, and neither of them is a claim that anything is open yet: the
    /// request has gone, and the project will be opened when the desk answers. Wake-on-LAN has no
    /// reply, so "sent" is the whole of what can honestly be said about the first half.
    static func deskIsBeingPrepared(_ machine: String, project: String) -> String {
        let what = project.isEmpty ? "the project you were last on" : project

        return "Sending the wake request now, sir. I'll have \(machine) open \(what) as soon as it answers."
    }

    /// Asked for while the desk is already up, so there is nothing to wake.
    static func deskIsAlreadyUp(_ machine: String) -> String {
        "\(machine) is already up, sir - I'll ask it to open that now."
    }

    /// Asked for with no way to wake the machine from here.
    static func cannotPrepareTheDesk(_ machine: String) -> String {
        "I can't wake \(machine) from here yet, sir, so there's nothing to open it on."
    }

    /// The desk has taken it on. Still not a claim that anything is open - the PC says that.
    static func deskHasTakenItOn(_ machine: String) -> String {
        "\(machine) is answering, sir. It's getting the desk ready now."
    }

    // MARK: When nothing can answer - priority §3B, §3E and §3F

    /// A question with no PC and no provider of this phone's own.
    ///
    /// Deliberately **not** "that one is your PC's". Two things could have answered it and
    /// neither is set up, so both are named with their remedies - which is the honest shape for a
    /// question nothing recognised, and the owner can then choose. Claiming it as the PC's
    /// property was wrong in two directions at once: untrue of a question about the world, and
    /// useless as advice, because waking a machine is no remedy for a missing key.
    static func neitherThePCNorAProvider(_ machine: String, canWake: Bool) -> String {
        let opening = "\(machine) isn't answering, sir, and this phone has no provider of its own yet."

        return canWake
            ? opening + " Say \u{201C}wake my PC\u{201D} and I'll ask it, or add a key in Settings "
                + "\u{203A} Cloud intelligence and I'll answer what I can here."
            : opening + " Add a key in Settings \u{203A} Cloud intelligence and I'll answer what I can here."
    }

    /// Something only the desk can do, with the desk asleep and wakeable.
    static func needsTheDeskAndItCanBeWoken(_ machine: String) -> String {
        "That one needs \(machine), sir, and it isn't answering. Say \u{201C}wake my PC\u{201D} and I'll switch it on, then ask me again."
    }

    /// Something only the desk can do, with the desk asleep and not wakeable from here.
    static func needsTheDeskAndItCannotBeWoken(_ machine: String) -> String {
        "That one needs \(machine), sir, and it isn't answering - and waking it from here isn't set up yet."
    }

    /// A question about the world right now, which nothing on this phone measures.
    ///
    /// Weather is the one that prompted this. The provider has no live readings, so an answer from
    /// it would be a plausible invention, and the owner would have no way to tell. Saying so is
    /// the only honest option and it is a short sentence.
    static func noLiveReadingOfTheWorld(_ what: String) -> String {
        "I've no live \(what) on this phone, sir, and I won't guess at it. Your PC has the feed."
    }

    static func noLiveReadingAndThePCCanBeWoken(_ what: String, _ machine: String) -> String {
        "I've no live \(what) on this phone, sir, and I won't guess at it. "
        + "\(machine) has the feed - say \u{201C}wake my PC\u{201D} and I'll ask it."
    }

    // MARK: What the machine is doing

    static func cannotTellWithoutTheService() -> String {
        "I can't tell while JARVIS isn't running, sir. Pair this phone with the PC's service and I'll be able to say whether it's off, locked, or just not signed in."
    }

    static func cannotReachAtAll(_ machine: String) -> String {
        "I can't reach \(machine) at all, sir, so it's either off or not on a network I can see from here."
    }

    static func nobodySignedIn(_ machine: String) -> String {
        "\(machine) is on, sir, but nobody has signed in yet, so JARVIS isn't running."
    }

    static func lockedWithJarvisRunning(_ machine: String) -> String {
        "\(machine) is locked, sir. JARVIS is running and will answer once you unlock it."
    }

    static func lockedWithoutJarvis(_ machine: String) -> String {
        "\(machine) is locked, sir, and JARVIS isn't running on it."
    }

    static func awakeWithJarvisRunning(_ machine: String) -> String {
        "\(machine) is awake and JARVIS is running, sir - I just couldn't reach it from here."
    }

    static func awakeWithoutJarvis(_ machine: String) -> String {
        "\(machine) is awake, sir, but JARVIS isn't running on it."
    }

    static func onButCannotSay(_ machine: String) -> String {
        "\(machine) is on, sir, but it couldn't say what it's doing."
    }

    // MARK: Batteries

    static func batteryNow(_ device: String, _ percent: Int, charging: String, saving: String) -> String {
        "\(device) is at \(percent) per cent\(charging)\(saving), sir."
    }

    static func batteryThen(_ device: String, _ percent: Int, minutes: Int) -> String {
        "\(device) was at \(percent) per cent, sir, \(minutes) minute\(minutes == 1 ? "" : "s") ago."
    }

    static func noBatteryReading(_ device: String, because: String?) -> String {
        guard let because else { return "I've no battery reading for \(device), sir." }
        return "I've no battery reading for \(device), sir - \(because)"
    }

    static func nothingReadable() -> String {
        "I can't read anything's battery at the moment, sir."
    }

    static func nothingCalledWithABattery(_ named: String) -> String {
        "I've nothing called \(named) with a battery I can read, sir."
    }

    // MARK: Devices this phone can work itself

    static func noSuchDevice() -> String {
        "I don't know a device by that name, sir."
    }

    /// Asked to switch something over when nothing has read which way it is.
    static func cannotToggleUnknown(_ device: String) -> String {
        "I don't know whether the \(device) is on at the moment, sir, so I can't switch it over. Say on or off and I'll do that."
    }

    static func switchedOn(_ device: String) -> String { "\(device) is on, sir." }

    static func switchedOff(_ device: String) -> String { "\(device) is off, sir." }

    static func pressed(_ device: String) -> String { "Pressed \(device), sir." }

    /// Sent and unconfirmed, which is a different fact from done.
    ///
    /// With the PC off the command goes straight to the vendor, which accepts it and says nothing
    /// about whether the light changed. Until a status read comes back, "sent" is the whole truth
    /// and "done" would be a claim about the room nobody has looked at.
    static func sentButUnconfirmed(_ device: String, _ state: String) -> String {
        state.isEmpty ? "\(device): sent, sir, though I can't confirm it from here."
                      : "\(device): \(state), sir."
    }

    // MARK: The register, as a list

    // MARK: Status - programme §58

    static func pcIsAnswering(_ machine: String) -> String {
        "\(machine) is answering, sir."
    }

    static func pcIsNotAnswering(_ machine: String, canWake: Bool) -> String {
        canWake
            ? "\(machine) isn't answering, sir. I can wake it from here."
            : "\(machine) isn't answering, sir."
    }

    static func houseUnreachable() -> String {
        "Nothing in the house can be switched from here at the moment, sir."
    }

    static func waitingToSync(_ count: Int) -> String {
        count == 1
            ? "One observation is waiting to reach your PC, sir."
            : "\(count) observations are waiting to reach your PC, sir."
    }

    static func catchingUp(_ count: Int) -> String {
        "I'm \(count) behind what your PC has, sir, and catching up."
    }

    static func nothingWantsAttention() -> String {
        "Nothing wants attention, sir."
    }

    /// Every phrase, rendered with stand-in values.
    ///
    /// Here so the register can be asserted across all of them at once rather than one test per
    /// sentence - and so a phrase added without a thought about how it reads fails the suite rather
    /// than shipping. Order is immaterial.
    static var everything: [String] {
        [
            wakingIsOff("DOM-PC"),
            cardUnknown("DOM-PC"),
            onlyFromHome("DOM-PC"),
            sendingWake("DOM-PC"),
            notACardAddress(),
            thePCsAndItCanBeWoken("DOM-PC"),
            thePCsAndItCannotBeWoken("DOM-PC"),
            thePCsAndNothingCanBeDone("DOM-PC"),
            cannotTellWithoutTheService(),
            cannotReachAtAll("DOM-PC"),
            nobodySignedIn("DOM-PC"),
            lockedWithJarvisRunning("DOM-PC"),
            lockedWithoutJarvis("DOM-PC"),
            awakeWithJarvisRunning("DOM-PC"),
            awakeWithoutJarvis("DOM-PC"),
            onButCannotSay("DOM-PC"),
            batteryNow("iPhone", 63, charging: "", saving: ""),
            batteryThen("iPhone", 60, minutes: 7),
            noBatteryReading("AirPods Pro", because: "iOS doesn't tell apps."),
            noBatteryReading("AirPods Pro", because: nil),
            nothingReadable(),
            nothingCalledWithABattery("the tractor"),
            noSuchDevice(),
            cannotToggleUnknown("Bedroom Light"),
            switchedOn("Bedroom Light"),
            switchedOff("Bedroom Light"),
            pressed("Desk Lamp"),
            sentButUnconfirmed("Bedroom Light", ""),
            sentButUnconfirmed("Bedroom Light", "On (unconfirmed)"),
            pcIsAnswering("DOM-PC"),
            pcIsNotAnswering("DOM-PC", canWake: true),
            pcIsNotAnswering("DOM-PC", canWake: false),
            houseUnreachable(),
            waitingToSync(1),
            waitingToSync(14),
            catchingUp(40),
            nothingWantsAttention(),

            // Priority §3C and §3B. In the list so the register tests hold them to the same rules
            // as everything else: the owner addressed, nothing claimed, nothing invented.
            hereAndListening(),
            greeting(),
            howIAm(),
            howIAmWithoutThePC("DOM-PC"),
            welcome(),
            untilLater(),
            neitherThePCNorAProvider("DOM-PC", canWake: true),
            neitherThePCNorAProvider("DOM-PC", canWake: false),
            needsTheDeskAndItCanBeWoken("DOM-PC"),
            needsTheDeskAndItCannotBeWoken("DOM-PC"),
            noLiveReadingOfTheWorld("weather"),
            noLiveReadingAndThePCCanBeWoken("weather", "DOM-PC"),

            // Priority §4.
            deskIsBeingPrepared("DOM-PC", project: ""),
            deskIsBeingPrepared("DOM-PC", project: "tow yard"),
            deskIsAlreadyUp("DOM-PC"),
            cannotPrepareTheDesk("DOM-PC"),
            deskHasTakenItOn("DOM-PC")
        ]
    }
}
