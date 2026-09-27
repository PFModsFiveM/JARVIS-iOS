import Foundation

/// What the PC says about whether it can be woken, read off its own hardware and settings.
///
/// Only the PC can see these - whether Windows lets the card wake it, whether the driver listens for
/// magic packets, what kind of sleep it uses, whether the dynamic-DNS name points at the house, and
/// whether the house has a public address at all. It is asked while the PC is awake (the bridge is up),
/// so that a wake that later does nothing already has its likely cause written down.
struct WakeReadinessReport: Equatable {
    struct Check: Equatable, Identifiable {
        enum State: String, Equatable {
            case ok = "Ok"
            case problem = "Problem"
            case note = "Note"
            /// Could not be read. Never shown as a fault.
            case unknown = "Unknown"
        }

        let id: String
        let state: State
        let title: String
        let detail: String
    }

    let checks: [Check]
    /// The parts of the wake path the PC cannot see, said so rather than left out.
    let cannotKnow: [String]
    let at: Date

    var firstProblem: Check? { checks.first { $0.state == .problem } }

    /// Reads a `wake.readiness` reply. Nil when it is not one.
    static func read(_ body: [String: Any], at: Date = Date()) -> WakeReadinessReport? {
        guard let rows = body["checks"] as? [[String: Any]] else { return nil }

        let checks = rows.compactMap { row -> Check? in
            guard let id = row["check"] as? String, let title = row["title"] as? String else { return nil }
            return Check(
                id: id,
                state: (row["state"] as? String).flatMap(Check.State.init(rawValue:)) ?? .unknown,
                title: title,
                detail: row["detail"] as? String ?? "")
        }

        return WakeReadinessReport(checks: checks, cannotKnow: body["cannotKnow"] as? [String] ?? [], at: at)
    }
}

/// What the PC heard while listening for a wake packet - the test of the route into the house that
/// can be run without putting the PC to sleep.
///
/// A packet the router forwards to the home network reaches the PC's network stack while it is awake
/// just as it would reach the card while it sleeps, so receiving one from outside proves the name,
/// the router's forward and the home network. It cannot prove the card wakes the machine, and the PC's
/// own `meaning` says so.
struct WakeProbeReport: Equatable {
    enum State: String, Equatable {
        case idle = "Idle"
        case listening = "Listening"
        case finished = "Finished"
        case couldNotListen = "CouldNotListen"
    }

    let state: State
    let port: Int
    let forThisPc: Int
    let forAnother: Int
    let fromOutside: Int
    let fromHome: Int
    /// The PC's own sentence for what this shows and does not show.
    let meaning: String

    var isListening: Bool { state == .listening }

    /// Reads a `wake.probe` reply. Nil when it is not one.
    static func read(_ body: [String: Any]) -> WakeProbeReport? {
        guard let state = (body["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }

        func number(_ key: String) -> Int { (body[key] as? NSNumber)?.intValue ?? 0 }

        return WakeProbeReport(
            state: state,
            port: number("port"),
            forThisPc: number("forThisPc"),
            forAnother: number("forAnother"),
            fromOutside: number("fromOutside"),
            fromHome: number("fromHome"),
            meaning: body["meaning"] as? String ?? "")
    }
}
