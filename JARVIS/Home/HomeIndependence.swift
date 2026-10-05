import Foundation

/// Why Mobile JARVIS cannot work a light, when it cannot - programme §2.
///
/// The point of naming these separately is that they have completely different remedies and look
/// identical from the outside. "The light didn't come on" is a credential the owner never added, a
/// binding the PC never taught this phone, a hub powered from the PC's own USB, a Bot whose battery
/// has gone, or a command that went through and could not be read back - and being told which one
/// is the difference between a fix and an evening of guessing.
enum HomeBlocker: Equatable, CaseIterable {
    case credential
    case binding
    case routing
    case network
    case vendor
    case hub
    case device
    case confirmation

    /// What the owner should do about it.
    var remedy: String {
        switch self {
        case .credential:
            return "Add this phone's own SwitchBot token in Settings. Without one the phone can only work the light through your PC."
        case .binding:
            return "Open JARVIS once while your PC is on. The PC tells this phone which switch is which, and it cannot do that while it is off."
        case .routing:
            return "The device is on a provider this phone can't reach by itself. It will still work through your PC."
        case .network:
            return "This phone has no connection, so it can't reach SwitchBot either. Wi-Fi or mobile data will do."
        case .vendor:
            return "SwitchBot didn't accept the account. Check the token and secret in Settings."
        case .hub:
            return "The SwitchBot Hub isn't online. If it's powered from your PC's USB, it is off whenever the PC is."
        case .device:
            return "The device isn't answering its hub. Usually a flat battery or something moved out of range."
        case .confirmation:
            return "The command went through, but nothing could read the switch back. It may well have worked."
        }
    }

    /// The one-word name a diagnostic prints, so the report and this agree.
    var title: String {
        switch self {
        case .credential: return "Credential"
        case .binding: return "Binding"
        case .routing: return "Routing"
        case .network: return "Network"
        case .vendor: return "SwitchBot account"
        case .hub: return "Hub"
        case .device: return "Device"
        case .confirmation: return "Confirmation"
        }
    }
}

/// One line of the independence report.
enum HomeCheck: Equatable {
    /// Known good. The detail is what makes it good, never a secret.
    case yes(String?)
    /// Known bad, with the reason.
    case no(String)
    /// Nothing has established it either way, which is honest and common.
    case unknown(String)

    var good: Bool { if case .yes = self { return true } else { return false } }

    var detail: String? {
        switch self {
        case .yes(let detail): return detail
        case .no(let why), .unknown(let why): return why
        }
    }

    /// YES / NO / UNKNOWN, as the brief asks the page to read.
    var word: String {
        switch self {
        case .yes: return "YES"
        case .no: return "NO"
        case .unknown: return "UNKNOWN"
        }
    }
}

/// Which way a command would go if one were issued now.
enum HomeRouteNow: Equatable {
    case pc
    case mobileDirect
    case unavailable(String)

    var word: String {
        switch self {
        case .pc: return "PC"
        case .mobileDirect: return "MOBILE DIRECT"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    /// Whether a command issued now would get anywhere at all.
    var possible: Bool {
        switch self {
        case .pc, .mobileDirect: return true
        case .unavailable: return false
        }
    }
}

/// Everything the independence page needs, worked out from plain values.
///
/// **No token or secret is anywhere in this type.** Whether one exists is a fact the owner needs;
/// what it is, is not, and a diagnostic page is exactly the sort of screen somebody photographs to
/// ask for help with.
struct HomeIndependence: Equatable {
    let credentials: HomeCheck
    let bindings: HomeCheck
    let device: HomeCheck
    let directRoute: HomeCheck
    let pcRoute: HomeCheck
    let hub: HomeCheck

    let lastCommandAt: Date?
    let lastResult: String?
    let lastConfirmedState: String?
    let routeNow: HomeRouteNow

    /// The one thing stopping it, when something is.
    let blocker: HomeBlocker?

    /// Whether a command issued now would get anywhere at all.
    var workable: Bool { routeNow.possible }

    /// What the last direct probe found, when one has run.
    ///
    /// Separate from the checks because a probe is evidence rather than configuration: it is the
    /// only thing that can turn "unknown" into "yes" for the hub and the device, and the only
    /// honest way to say the whole chain works.
    struct Probe: Equatable {
        let at: Date
        let outcome: StandbyOutcome
        let device: String
        let battery: Int?

        var blocker: HomeBlocker? {
            switch outcome {
            case .confirmed: return nil
            case .sent: return .confirmation
            case .unavailable: return .network
            case .ambiguous: return .confirmation
            case .offline(let why):
                return why.contains("Hub") ? .hub : .device
            case .failed(let why):
                return why.contains("token") ? .vendor : .device
            }
        }
    }

    /// Reads the state of Mobile independence.
    ///
    /// - Parameters:
    ///   - credentials: whether this phone has a SwitchBot token of its own. The value is not read.
    ///   - bindings: what the PC has taught this phone it can reach.
    ///   - pcAnswering: whether the bridge is up right now.
    ///   - preferred: the device the page is about - the one light, or the first binding.
    ///   - probe: what the last direct read found, when one has run.
    static func read(
        credentials: SwitchBotCredentials?,
        bindings: [StandbyDevice],
        pcAnswering: Bool,
        preferred: StandbyDevice? = nil,
        probe: Probe? = nil,
        lastCommandAt: Date? = nil,
        lastResult: String? = nil,
        lastConfirmedState: String? = nil,
        networkUp: Bool = true
    ) -> HomeIndependence {
        let hasToken = credentials?.usable == true
        let subject = preferred ?? bindings.first

        let credentialCheck: HomeCheck = hasToken
            ? .yes("This phone has its own token")
            : .no("No token on this phone")

        let bindingCheck: HomeCheck = bindings.isEmpty
            ? .no("The PC hasn't told this phone what it can reach")
            : .yes("\(bindings.count) device\(bindings.count == 1 ? "" : "s") learned")

        let deviceCheck: HomeCheck = subject.map { .yes($0.name) } ?? .no("No device to work")

        // A route this phone could take by itself. Needs a token, a binding, and a provider this
        // phone can actually talk to - all three, which is why the three are separate lines above.
        let reachable = subject?.provider == "SwitchBot"
        let directCheck: HomeCheck
        if !hasToken {
            directCheck = .no("Needs this phone's own token")
        } else if subject == nil {
            directCheck = .no("Needs a binding from the PC")
        } else if !reachable {
            directCheck = .no("\(subject!.name) is on \(subject!.provider), which this phone can't reach by itself")
        } else {
            directCheck = .yes("Straight to SwitchBot")
        }

        let pcCheck: HomeCheck = pcAnswering
            ? .yes("The PC is answering")
            : .no("The PC isn't answering")

        // Nothing can know this without asking the vendor, and the only thing that asks is the
        // probe. Unknown is the truth until one has run - saying anything else would be a guess
        // about the one component most likely to be off when the PC is.
        let hubCheck: HomeCheck
        if let probe {
            switch probe.outcome {
            case .confirmed, .sent: hubCheck = .yes("Answered a status read")
            case .offline(let why) where why.contains("Hub"): hubCheck = .no("The hub isn't online")
            case .offline: hubCheck = .yes("The hub answered; the device did not")
            default: hubCheck = .unknown("The last read didn't get that far")
            }
        } else {
            hubCheck = .unknown("Nothing has asked it yet")
        }

        let route: HomeRouteNow
        if pcAnswering {
            route = .pc
        } else if directCheck.good {
            route = .mobileDirect
        } else {
            route = .unavailable(directCheck.detail ?? "Nothing can reach it from here")
        }

        return HomeIndependence(
            credentials: credentialCheck,
            bindings: bindingCheck,
            device: deviceCheck,
            directRoute: directCheck,
            pcRoute: pcCheck,
            hub: hubCheck,
            lastCommandAt: lastCommandAt,
            lastResult: lastResult,
            lastConfirmedState: lastConfirmedState,
            routeNow: route,
            blocker: Self.blocking(
                hasToken: hasToken,
                bindings: bindings,
                subject: subject,
                reachable: reachable,
                pcAnswering: pcAnswering,
                networkUp: networkUp,
                probe: probe))
    }

    /// The first thing in the chain that is wrong.
    ///
    /// In order, because the order is the chain: there is no point telling the owner the hub is
    /// unreachable when the real problem is that this phone has no token and never asked it.
    private static func blocking(
        hasToken: Bool,
        bindings: [StandbyDevice],
        subject: StandbyDevice?,
        reachable: Bool,
        pcAnswering: Bool,
        networkUp: Bool,
        probe: Probe?
    ) -> HomeBlocker? {
        // With the PC answering there is a working route whatever else is missing, so nothing is
        // blocking control - only independence, which the lines above already report.
        if pcAnswering { return nil }

        if !hasToken { return .credential }
        if bindings.isEmpty || subject == nil { return .binding }
        if !reachable { return .routing }
        if !networkUp { return .network }

        return probe?.blocker
    }
}
