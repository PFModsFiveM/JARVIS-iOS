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

            return state.pcAnswering
                ? MobileDecision(.pcPrime, fallback: mine)
                : MobileDecision(mine)
        }

        if state.pcAnswering { return MobileDecision(.pcPrime) }

        // Nothing here can do it and the PC is not there. A general question still has somewhere to
        // go when the owner has given this phone a provider of its own.
        if state.cloudReady {
            return MobileDecision(.cloud, fallback: .unavailable(waiting(state)))
        }

        return MobileDecision(.unavailable(waiting(state)))
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
