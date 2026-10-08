import Foundation

// MARK: - What this node is
//
// Mobile JARVIS is a node of JARVIS, not a remote control for it. That distinction is easy to
// state and easy to lose, and it was being lost in one specific place: with the PC off, a request
// that needed the PC fell through to the bridge, the bridge threw, and the phone showed a socket
// error. JARVIS does not answer "Connection refused". It says which machine would do that, that
// the machine is not answering, and what it can offer instead.
//
// So the two things that were missing are here. A *declaration* of what this phone can do by
// itself and what needs PC-Prime, with each one's live readiness - which is what lets the phone
// answer "what can you do with my PC off?" and what the Settings page renders. And one routing
// decision, built on `LocalCapability`, which already reads the sentences that cannot be sent to a
// sleeping PC. Nothing here re-reads a sentence: `LocalCapability` stays the only thing that does.
//
// The rule for what belongs to this node is unchanged and still narrow: only what is impossible
// while the PC is off. Everything else goes to the PC, where the understanding and the state are.
// A phone that reimplemented JARVIS's judgement in its own word lists would be a worse JARVIS
// wearing the same name.

/// Which machine carries a request out.
enum JarvisNode: String, Codable, Hashable {
    case thisPhone
    case pcPrime

    var title: String {
        switch self {
        case .thisPhone: return "This phone"
        case .pcPrime: return "PC-Prime"
        }
    }
}

/// Whether a capability can be used at this moment, and what it would take if not.
enum CapabilityReadiness: Equatable {
    /// Usable now, and still usable with the PC off. The interesting case, and the whole point.
    case standalone
    /// Usable now, through the PC.
    case throughThePC
    /// This phone could do it, but something has to be set up first. The words say what.
    case needs(String)
    /// Only PC-Prime can do it, and PC-Prime is not answering.
    case waitingForThePC

    var usable: Bool { self == .standalone || self == .throughThePC }
}

/// One thing JARVIS can be asked for, and where it happens.
struct MobileCapabilityCard: Identifiable, Equatable {
    /// Stable, so a test and the page can name the same card. Not shown.
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let node: JarvisNode
    let readiness: CapabilityReadiness
}

enum MobileCapabilities {

    /// Everything the readiness of a capability depends on, as plain values.
    ///
    /// A struct rather than a reach into four singletons, so what this phone says it can do is
    /// decided by a function of its state and can be tested without an app, a PC or a network.
    struct NodeState: Equatable {
        var pcName: String = "your PC"
        /// Answering *now*. Not "was recently": a request sent to a PC that stopped answering is
        /// the failure this whole feature exists to avoid.
        var pcAnswering: Bool = false
        var servicePaired: Bool = false
        var wakeEnabled: Bool = false
        /// Whether a wake request has somewhere to go from where this phone is standing.
        var wakeReachable: Bool = false
        var hasOwnDeviceToken: Bool = false
        var reachableDevices: Int = 0
        var footageJoined: Bool = false
        var locationReporting: Bool = false
        var alertsOn: Bool = false
        /// Whether this phone has a cloud provider of its own to answer a general question with.
        /// False until the owner configures one: nothing is shipped with a key.
        var cloudReady: Bool = false
    }

    // MARK: The declaration

    static func cards(_ state: NodeState) -> [MobileCapabilityCard] {
        [
            MobileCapabilityCard(
                id: "wake",
                title: "Switch \(state.pcName) on",
                detail: "A wake request goes from this phone to the network card, which is awake even when the machine is not. Nothing else can do this: a sleeping PC cannot be asked to wake itself.",
                symbol: "power",
                node: .thisPhone,
                readiness: wakeReadiness(state)),

            MobileCapabilityCard(
                id: "state",
                title: "Say what \(state.pcName) is doing",
                detail: "Off, on with nobody signed in, locked, or awake - answered by the PC's pre-login service, which runs before JARVIS does.",
                symbol: "desktopcomputer",
                node: .thisPhone,
                readiness: state.servicePaired
                    ? .standalone
                    : .needs("Pair this phone with the PC's service, on its Settings \u{203A} iPhone page.")),

            MobileCapabilityCard(
                id: "devices",
                title: "Work a light or a plug",
                detail: "Normally the command goes through the PC, which owns the state and tells every other device what changed. With the PC off, this phone sends it to the vendor itself - for the devices the PC taught it, and only those.",
                symbol: "lightbulb",
                node: .thisPhone,
                readiness: deviceReadiness(state)),

            MobileCapabilityCard(
                id: "footage",
                title: "Look at what the camera kept",
                detail: "What the PC already uploaded, read from the shared store. There is no live view with the PC off and there cannot be - the camera is plugged into it.",
                symbol: "film",
                node: .thisPhone,
                readiness: state.footageJoined
                    ? .standalone
                    : .needs("Join the store from the PC, then add a read-only key on this phone.")),

            MobileCapabilityCard(
                id: "whereabouts",
                title: "Notice when you leave and come home",
                detail: "Recorded on this phone whether the PC is up or not, and sent on when it comes back.",
                symbol: "location",
                node: .thisPhone,
                readiness: state.locationReporting
                    ? .standalone
                    : .needs("Switch on \u{201C}Tell the PC where I am\u{201D}, and allow location always.")),

            MobileCapabilityCard(
                id: "alerts",
                title: "Reach you with this app closed",
                detail: "Security challenges, reminders and announcements arrive through ntfy, which does not need JARVIS to be open or this phone to be at home.",
                symbol: "bell",
                node: .thisPhone,
                readiness: state.alertsOn
                    ? .standalone
                    : .needs("Switch on alerts, and add the topic to the ntfy app.")),

            MobileCapabilityCard(
                id: "speak",
                title: "Speak an answer",
                detail: "In JARVIS's own voice when the PC sends it with the answer, and in the iPhone's otherwise.",
                symbol: "waveform",
                node: .thisPhone,
                readiness: .standalone),

            // What the other node does. The phone knowing this is the point: it is how a request
            // that belongs to PC-Prime gets an answer about PC-Prime rather than a network error.
            MobileCapabilityCard(
                id: "ask",
                title: "Answer anything else",
                detail: "Understanding, memory, research, the browser, files, projects, games - JARVIS itself, on the machine where it lives.",
                symbol: "brain",
                node: .pcPrime,
                readiness: state.pcAnswering ? .throughThePC : .waitingForThePC),

            MobileCapabilityCard(
                id: "screen",
                title: "Show and work the screen",
                detail: "Watching the desktop and taking the mouse and keyboard, which is the PC describing and acting on itself.",
                symbol: "display",
                node: .pcPrime,
                readiness: state.pcAnswering ? .throughThePC : .waitingForThePC),

            MobileCapabilityCard(
                id: "security",
                title: "Run the Security Protocol",
                detail: "The camera, the challenge and the lock are the PC's. This phone is where the challenge is answered.",
                symbol: "lock.shield",
                node: .pcPrime,
                readiness: state.pcAnswering ? .throughThePC : .waitingForThePC)
        ]
    }

    /// The ones usable with the PC off, which is the question anybody actually asks.
    static func standalone(_ state: NodeState) -> [MobileCapabilityCard] {
        cards(state).filter { $0.readiness == .standalone }
    }

    private static func wakeReadiness(_ state: NodeState) -> CapabilityReadiness {
        if !state.wakeEnabled { return .needs("Switch Wake-on-LAN on.") }
        if !state.wakeReachable {
            return .needs("This phone does not know \(state.pcName)'s network card yet. Connect to it once at home and it will say.")
        }
        return .standalone
    }

    private static func deviceReadiness(_ state: NodeState) -> CapabilityReadiness {
        // Two separate things, and saying which is missing is the difference between a useful
        // sentence and "not configured". A token without bindings and bindings without a token
        // both leave the light unreachable, for different reasons and with different remedies.
        if !state.hasOwnDeviceToken && state.reachableDevices == 0 {
            return .needs("Add this phone's own SwitchBot token, then connect to the PC once so it can say which devices this phone may work.")
        }
        if !state.hasOwnDeviceToken { return .needs("Add this phone's own SwitchBot token.") }
        if state.reachableDevices == 0 {
            return .needs("Connect to the PC once while it is on, so it can say which devices this phone may work.")
        }
        return .standalone
    }

    // MARK: Routing

    /// Where a request is carried out.
    /// Which node carries a request out.
    ///
    /// The five lanes are the whole routing vocabulary, and the names are the ones the architecture
    /// uses so a diagnostic, a test and a log line all say the same word:
    ///
    /// - `localMobile` - this phone, from what it knows itself. A battery, a wake packet, what the
    ///   pre-login service says Windows is doing.
    /// - `directDevice` - this phone to a vendor, bypassing the PC because the PC cannot relay.
    /// - `pcPrime` - delegated to the PC, which understands the sentence better than any reading
    ///   here and owns the state of everything at the desk.
    /// - `cloud` - a general question answered without the PC, when the owner has configured a
    ///   provider. Text only: see `CloudIntelligence`.
    /// - `unavailable` - nothing can do it, said in words rather than as a transport error.
    enum MobileLane: Equatable {
        case localMobile(LocalCapability)
        case directDevice(LocalCapability)
        case pcPrime
        case cloud
        case unavailable(String)

        /// Whether this lane needs the PC to be answering.
        var needsThePC: Bool { self == .pcPrime }

        /// The capability behind a lane this phone carries out itself.
        var capability: LocalCapability? {
            switch self {
            case .localMobile(let capability), .directDevice(let capability): return capability
            case .pcPrime, .cloud, .unavailable: return nil
            }
        }
    }

    /// The lane a request takes, and what to do if that lane turns out not to work.
    ///
    /// The fallback is the part that was missing. A lane is chosen from what was true a moment ago -
    /// "the bridge is up" - and the gap between choosing and sending is exactly where a PC goes to
    /// sleep. Without a second lane the owner gets a transport error for a light this phone could
    /// have switched itself, which is the failure the whole standalone path exists to prevent.
    struct MobileDecision: Equatable {
        let lane: MobileLane
        let fallback: MobileLane?

        init(_ lane: MobileLane, fallback: MobileLane? = nil) {
            self.lane = lane
            self.fallback = fallback
        }
    }

    // MARK: What kind of request it is - priority §3B, §3E and §3F

    /// What a sentence would need, when nothing on this phone matched it.
    ///
    /// **This is not a second reading of the sentence for routing.** Routing is decided by
    /// `LocalCapability` and by whether the PC is answering, exactly as before. This decides only
    /// the *words* used when nothing can carry a request out - and it exists because one sentence
    /// was answered with another's explanation. "What's the weather?" and "How are you?" came back
    /// as "That one is DOM-PC's, sir, and it isn't answering", which is wrong twice: a question
    /// about the world is not a machine's property, and offering to boot a PC is no remedy for it.
    ///
    /// Note the direction of the lists. Only the *desk* is matched positively; an unmatched
    /// sentence is a general question, not a PC action. A phone that treated everything it did not
    /// recognise as the PC's would be back where it started.
    enum RequestShape: Equatable {
        /// Something only the machine at the desk can do: an application, a file, the screen.
        case theDesk

        /// A fact about the world as it is right now, which nothing on this phone measures.
        /// Carries what was asked for - "weather", "prices" - so the sentence can name it.
        case liveFact(String)

        /// Everything else. Answerable by a provider, and answerable without the PC.
        case general
    }

    /// Which shape a sentence has, for the words only.
    static func shape(_ sentence: String) -> RequestShape {
        let words = Set(sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })

        // A live fact first, because "what is the weather doing" contains a doing word and would
        // otherwise read as an action at the desk.
        //
        // Asking *about* a subject is not asking for its current value, though, and a provider can
        // explain how a barometer works perfectly well. So an explanatory framing takes the
        // sentence back out of this class - which is the difference between "what's the weather"
        // and "how does weather radar work".
        if words.isDisjoint(with: explaining) {
            for (asked, named) in liveFacts where !words.isDisjoint(with: asked) {
                return .liveFact(named)
            }
        }

        // Something at the desk. Both halves have to be present: a doing word and a thing at the
        // desk to do it to. "Open Blender" qualifies; "how do I open a bank account" does not.
        let doing: Set<String> = [
            "open", "launch", "start", "run", "close", "quit", "kill", "minimise", "minimize",
            "maximise", "maximize", "move", "resize", "install", "uninstall", "download", "save",
            "delete", "rename", "copy", "paste", "type", "click", "scroll", "screenshot", "record",
            "play", "pause", "skip", "mute", "render", "build", "compile", "lock", "unlock"
        ]

        let atTheDesk: Set<String> = [
            "app", "application", "apps", "window", "windows", "screen", "desktop", "file",
            "files", "folder", "folders", "document", "documents", "program", "programme",
            "project", "projects", "game", "games", "browser", "tab", "tabs", "blender", "steam",
            "spotify", "discord", "chrome", "edge", "firefox", "vscode", "explorer", "terminal",
            "clipboard", "mouse", "keyboard", "taskbar", "monitor", "monitors"
        ]

        if !words.isDisjoint(with: doing) && !words.isDisjoint(with: atTheDesk) { return .theDesk }

        // Naming a thing at the desk and asking about it is still the desk's: "what's on my
        // screen", "which projects do I have".
        if !words.isDisjoint(with: atTheDesk) && !words.isDisjoint(with: ["what", "whats", "which", "where", "show", "list"]) {
            return .theDesk
        }

        return .general
    }

    /// The things nothing on this phone can measure, and the word to call each one.
    ///
    /// Weather is the one the owner found. The rest are here because they fail the same way: a
    /// provider with no tools will answer them fluently and be making it up, and a phone that read
    /// that out would be lying with JARVIS's voice.
    /// Words that make a sentence a question about a subject rather than about its current value.
    private static let explaining: Set<String> = [
        "explain", "mean", "means", "meaning", "definition", "work", "works", "working",
        "why", "history", "difference", "between", "typically", "generally", "usually"
    ]

    private static let liveFacts: [(Set<String>, String)] = [
        (["weather", "forecast", "temperature", "raining", "rain", "snowing", "sunny"], "weather"),
        (["price", "prices", "stock", "stocks", "shares", "ticker"], "market data"),
        (["news", "headlines"], "news"),
        (["score", "scores", "fixture", "fixtures", "kickoff"], "sports data"),
        (["traffic"], "traffic")
    ]

    /// What to say when nothing can carry a request out - priority §3B, §3E and §3F.
    ///
    /// Three different sentences for three different situations, where there used to be one. The
    /// desk's work offers to wake the desk; a live fact says plainly that it will not be guessed
    /// at; and a general question says what it actually needs, which is a provider key and not a
    /// PC. Waking is offered only where waking is the remedy.
    static func nothingCanDoIt(_ sentence: String, state: NodeState) -> String {
        let wakeable = state.wakeEnabled && state.wakeReachable

        switch shape(sentence) {
        case .theDesk:
            return wakeable
                ? MobilePhrases.needsTheDeskAndItCanBeWoken(state.pcName)
                : MobilePhrases.needsTheDeskAndItCannotBeWoken(state.pcName)

        case .liveFact(let what):
            return wakeable
                ? MobilePhrases.noLiveReadingAndThePCCanBeWoken(what, state.pcName)
                : MobilePhrases.noLiveReadingOfTheWorld(what)

        case .general:
            // Not claimed as the PC's. Two things could have answered it - the desk, and a
            // provider of this phone's own - so when neither is there both are named with their
            // remedies, and the owner picks. When a provider *is* configured, this is the
            // cloud lane's fallback rather than the first word, and by then the desk is the only
            // thing left to wait for.
            return state.cloudReady
                ? (wakeable
                    ? MobilePhrases.needsTheDeskAndItCanBeWoken(state.pcName)
                    : MobilePhrases.needsTheDeskAndItCannotBeWoken(state.pcName))
                : MobilePhrases.neitherThePCNorAProvider(state.pcName, canWake: wakeable)
        }
    }

    /// Decides which node a sentence belongs to, and which node catches it if that one drops.
    ///
    /// The order is the architecture, and it has not changed: a PC that is answering gets
    /// everything, including the requests this phone *could* handle, because it understands the
    /// sentence better and owns the device state. What is new is that choosing the PC no longer
    /// throws away the knowledge that this phone could have done it - that becomes the fallback,
    /// and the PC dropping between the decision and the request is no longer the owner's problem.
    static func decide(_ sentence: String, devices: [StandbyDevice], state: NodeState) -> MobileDecision {
        let local = LocalCapability.of(sentence, devices: devices)

        if let local {
            // A device command has two genuine routes. Everything else this phone can do - a
            // battery, a wake, a machine's own state - has one, and it is this phone.
            let mine: MobileLane = local.isADeviceCommand ? .directDevice(local) : .localMobile(local)

            // Some questions this phone answers better than the PC can, and preferring the PC for
            // them would be a round trip to get a worse answer. Where the owner is, is the clear
            // case: the PC's belief rests on the last fix this phone sent it, and this phone has a
            // fresher one in hand. So it stays here whether or not the desk is awake.
            if local.answeredBestHere { return MobileDecision(mine) }

            // A pleasantry takes this same path on purpose - priority §3C. With the desk awake the
            // PC says hello, because it knows what it has been doing; with the desk asleep this
            // phone says it, which is the whole of the complaint that "how are you?" came back as
            // "that one is your PC's".
            return state.pcAnswering
                ? MobileDecision(.pcPrime, fallback: mine)
                : MobileDecision(mine)
        }

        if state.pcAnswering { return MobileDecision(.pcPrime) }

        // A fact about the world as it is right now - priority §3F. Nothing on this phone measures
        // it, and a provider with no tools has no honest answer either: it would produce a
        // plausible temperature and the owner would have no way to tell. So this is refused in
        // words rather than sent somewhere that would guess. The PC, which has the feed, answers
        // it normally - the rung above this one.
        if case .liveFact = shape(sentence) {
            return MobileDecision(.unavailable(nothingCanDoIt(sentence, state: state)))
        }

        // Nothing here can do it and the PC is not there. A general question still has somewhere to
        // go when the owner has given this phone a provider of its own - and what is said when it
        // does not now depends on what was actually asked, rather than calling everything the PC's.
        if state.cloudReady {
            return MobileDecision(.cloud, fallback: .unavailable(nothingCanDoIt(sentence, state: state)))
        }

        return MobileDecision(.unavailable(nothingCanDoIt(sentence, state: state)))
    }

    /// Whether a request to the PC certainly did not happen, or merely might not have.
    ///
    /// The distinction the fallback turns on - programme §7B. A connection that was never
    /// established is a request that never left; a reply that timed out after the request went is
    /// a request that may well have been carried out, with only the answer lost on the way back.
    enum Delivery: Equatable {
        /// There was no route at all. Nothing happened at the other end.
        case neverSent

        /// It left, and what became of it is unknown.
        case unknown
    }

    /// Whether the fallback lane may be tried after the PC lane failed - programme §7B.
    ///
    /// **A toggle is not a retry.** If the PC may have received "switch the lamp" and only the
    /// reply was lost, sending the same thing down the direct route presses a physical rocker a
    /// second time - and the owner, who asked for one thing, gets the light back where it started
    /// and no idea why. An explicit ON or OFF is safe to repeat, because arriving twice at "on" is
    /// still on. That asymmetry is the whole rule, and it is the same one the PC's own provider
    /// applies when a vendor request goes ambiguous.
    ///
    /// Everything that is not a device command may always be retried: a question asked twice is a
    /// question answered twice, which costs a moment and changes nothing.
    static func mayFallBack(to lane: MobileLane, after delivery: Delivery) -> Bool {
        if delivery == .neverSent { return true }

        guard let capability = lane.capability, capability.isADeviceCommand else { return true }

        switch capability {
        case .device(_, let command):
            // On and off are idempotent; a press is not, and SwitchBot has no toggle - so a
            // device that prefers a press is exactly the case this exists for.
            return command == .on || command == .off

        case .deviceToggle:
            // A toggle is never idempotent, by definition.
            return false

        default:
            return true
        }
    }

    /// What to say when a fallback was refused rather than tried.
    ///
    /// Honest about the uncertainty rather than claiming either outcome. The owner can look, which
    /// is cheaper than JARVIS guessing and being wrong in the direction that undoes their request.
    static func mayHaveHappened(_ name: String) -> String {
        "I sent that to your PC and didn't hear back, sir. It may have gone through - "
        + "I won't send it again, in case \(name) ends up back where it started."
    }

    /// What to say when the request belongs to a PC that is not answering.
    ///
    /// Never "done", never a transport error, and never a guess at the answer the PC would have
    /// given. What it offers depends on what this phone can actually do about it, which is the
    /// honest difference between "I'll wake it" and "I can't reach it from here".
    static func waiting(_ state: NodeState) -> String {
        let name = state.pcName

        if state.wakeEnabled && state.wakeReachable {
            return MobilePhrases.thePCsAndItCanBeWoken(name)
        }

        if state.servicePaired {
            return MobilePhrases.thePCsAndItCannotBeWoken(name)
        }

        return MobilePhrases.thePCsAndNothingCanBeDone(name)
    }
}
