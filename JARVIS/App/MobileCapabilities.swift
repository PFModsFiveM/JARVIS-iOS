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
    enum Route: Equatable {
        /// This phone, by a capability it has: `LocalCapability` decided which.
        case thisPhone(LocalCapability)
        /// PC-Prime, which is answering.
        case pcPrime
        /// PC-Prime is the only node that could, and it is not answering. The words are the answer.
        case waitingForThePC(String)
    }

    /// Decides which node a sentence belongs to.
    ///
    /// The order is the architecture. A PC that is answering gets everything, including the three
    /// requests this phone *could* handle: the PC understands the sentence better than any reading
    /// here, owns the device state, and tells every other node what changed. Only once the PC is
    /// not answering does this phone consider doing something itself - and then only the narrow set
    /// `LocalCapability` recognises.
    ///
    /// What is new is the third answer. A request that needs the PC, with the PC off, used to be
    /// sent anyway and fail as a transport error. It is a sentence JARVIS can answer perfectly
    /// well - *that machine does this, it is not answering, here is what I can do* - and a node
    /// that knows what the other nodes do is able to say it.
    static func route(_ sentence: String, devices: [StandbyDevice], state: NodeState) -> Route {
        if state.pcAnswering { return .pcPrime }

        if let local = LocalCapability.of(sentence, devices: devices) {
            return .thisPhone(local)
        }

        return .waitingForThePC(waiting(state))
    }

    /// What to say when the request belongs to a PC that is not answering.
    ///
    /// Never "done", never a transport error, and never a guess at the answer the PC would have
    /// given. What it offers depends on what this phone can actually do about it, which is the
    /// honest difference between "I'll wake it" and "I can't reach it from here".
    static func waiting(_ state: NodeState) -> String {
        let name = state.pcName

        if state.wakeEnabled && state.wakeReachable {
            return "That one is \(name)'s, sir, and it isn't answering. Say \u{201C}wake my PC\u{201D} and I'll switch it on, then ask me again."
        }

        if state.servicePaired {
            return "That one is \(name)'s, sir, and it isn't answering. I can tell you what it's doing, but waking it isn't set up from here yet."
        }

        return "That one is \(name)'s, sir, and it isn't answering. There's nothing I can do about it from this phone until waking it is set up."
    }
}
