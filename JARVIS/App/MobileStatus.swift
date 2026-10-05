import Foundation

/// One subsystem and whether it can be used right now - programme §4.
///
/// The point of listing these separately is that "JARVIS is offline" is almost never true. With
/// PC-PRIME asleep the smart home still works, the footage is still readable, the phone still
/// knows where it is and what its battery is doing, and a general question can still be answered
/// if the owner has given this phone a provider. A single status that collapsed all of that into
/// one word would be wrong in the most useful direction.
struct MobileAvailability: Identifiable, Equatable {
    enum State: Equatable {
        case online(String?)
        case available(String?)
        case unavailable(String)
        case notSetUp(String)

        /// ONLINE / AVAILABLE / UNAVAILABLE / NOT SET UP, as the panel reads.
        var word: String {
            switch self {
            case .online: return "ONLINE"
            case .available: return "AVAILABLE"
            case .unavailable: return "UNAVAILABLE"
            case .notSetUp: return "NOT SET UP"
            }
        }

        var usable: Bool {
            switch self {
            case .online, .available: return true
            case .unavailable, .notSetUp: return false
            }
        }

        var detail: String? {
            switch self {
            case .online(let detail), .available(let detail): return detail
            case .unavailable(let why), .notSetUp(let why): return why
            }
        }
    }

    let id: String
    let title: String
    let state: State
}

/// What Mobile JARVIS can say about itself - programme §4 and §58.
///
/// Pure, and a function of its arguments, so the panel and the spoken answer are built from one
/// reading and cannot disagree. The same reasoning as `MobileCapabilities`: a status assembled by
/// reaching into six singletons is a status that can only be checked by running the app.
enum MobileStatus {
    /// Every subsystem, in the order the owner cares about.
    static func availability(
        _ state: MobileCapabilities.NodeState,
        footageHeld: Bool = false
    ) -> [MobileAvailability] {
        [
            MobileAvailability(
                id: "mobile",
                title: "Mobile node",
                // This phone is the one node that is always here, by definition: it is the thing
                // being asked.
                state: .online(nil)),

            MobileAvailability(
                id: "pc",
                title: state.pcName,
                state: state.pcAnswering
                    ? .online(nil)
                    : state.wakeEnabled && state.wakeReachable
                        ? .unavailable("Not answering - can be woken from here")
                        : .unavailable("Not answering")),

            MobileAvailability(
                id: "home",
                title: "Smart home",
                state: homeState(state)),

            MobileAvailability(
                id: "cloud",
                title: "Cloud intelligence",
                state: state.cloudReady
                    ? .available(nil)
                    : .notSetUp("Add a provider key in Settings")),

            MobileAvailability(
                id: "footage",
                title: "Security archive",
                state: state.footageJoined
                    ? .available(footageHeld ? nil : "Nothing recorded yet")
                    : .notSetUp("Join the shared store while your PC is on")),

            MobileAvailability(
                id: "whereabouts",
                title: "Location",
                state: state.locationReporting
                    ? .online(nil)
                    : .notSetUp("Turn it on in Settings")),

            MobileAvailability(
                id: "alerts",
                title: "Notifications",
                state: state.alertsOn ? .available(nil) : .notSetUp("Turn them on in Settings"))
        ]
    }

    /// Whether the smart home can be worked, and by which route.
    private static func homeState(_ state: MobileCapabilities.NodeState) -> MobileAvailability.State {
        if state.pcAnswering { return .available("Through \(state.pcName)") }
        if state.reachableDevices == 0 { return .notSetUp("Connect once while your PC is on") }
        if !state.hasOwnDeviceToken { return .notSetUp("Add this phone's SwitchBot token") }

        return .available("Straight to SwitchBot")
    }

    /// Whether anything at all can be done. False only when genuinely nothing can.
    ///
    /// Programme §54: no mode may collapse into a meaningless "JARVIS offline" unless nothing is
    /// available - and this phone always has itself, so the honest answer is almost never no.
    static func anythingUsable(_ state: MobileCapabilities.NodeState) -> Bool {
        availability(state).contains { $0.state.usable }
    }

    // MARK: "Jarvis, status" - programme §58

    /// The spoken answer. Short, and nothing dull in it.
    ///
    /// The same rule as the PC's `EcosystemStatus`: a status reciting every healthy thing every
    /// time would train the owner to stop listening, and then the one that mattered would go past
    /// unheard. So what is said is what is not where it should be - and when everything is, that.
    static func say(
        _ state: MobileCapabilities.NodeState,
        power: [PowerReading] = [],
        queued: Int = 0,
        behind: Int64 = 0,
        lowAt: Int = 20
    ) -> [String] {
        var lines: [String] = []

        lines.append(state.pcAnswering
            ? MobilePhrases.pcIsAnswering(state.pcName)
            : MobilePhrases.pcIsNotAnswering(state.pcName,
                                             canWake: state.wakeEnabled && state.wakeReachable))

        // Anything running low and not on charge.
        let low = power.filter { reading in
            guard let percent = reading.percent, percent <= lowAt else { return false }
            return reading.charge != .charging && reading.charge != .full
        }

        if !low.isEmpty {
            lines.append(PowerReporter.sayAll(low))
        }

        // Whether the house can be worked at all.
        if !homeState(state).usable {
            lines.append(MobilePhrases.houseUnreachable())
        }

        // Whether anything is waiting to reach the PC. Said only when it is: synchronisation
        // working is the normal case and does not need reporting.
        if queued > 0 {
            lines.append(MobilePhrases.waitingToSync(queued))
        } else if behind > 0 {
            lines.append(MobilePhrases.catchingUp(Int(behind)))
        }

        if lines.count == 1 && state.pcAnswering {
            lines.append(MobilePhrases.nothingWantsAttention())
        }

        return lines
    }

    static func line(
        _ state: MobileCapabilities.NodeState,
        power: [PowerReading] = [],
        queued: Int = 0,
        behind: Int64 = 0
    ) -> String {
        say(state, power: power, queued: queued, behind: behind).joined(separator: " ")
    }
}
