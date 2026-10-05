import Foundation

/// Where an unlock has got to.
///
/// Every one of these comes from something that happened, never from something that was asked
/// for. `signingIn` is not entered because the authorization was accepted - it is entered because
/// the PC said it was, and `unlocked` is not entered until the service reports the session is in
/// use. The distinction is the whole reason this is a state machine rather than a spinner: the
/// phone cannot see Windows, so the only honest thing it can show is what the machine last said.
enum UnlockStage: Equatable {
    case idle

    /// Connecting, and asking for a challenge.
    case asking

    /// The Face ID sheet is up. The owner is deciding.
    case faceID

    /// Signed, and being sent.
    case authorizing

    /// The PC accepted the authorization. Windows is deciding, and may refuse.
    case signingIn

    /// Windows let somebody in. Desktop JARVIS has not answered yet.
    case desktopStarting

    /// The session is in use and desktop JARVIS is up.
    case online

    case stopped(UnlockStop)

    /// Whether an unlock is in flight, and a second tap should do nothing.
    var busy: Bool {
        switch self {
        case .idle, .online, .stopped: return false
        case .asking, .faceID, .authorizing, .signingIn, .desktopStarting: return true
        }
    }

    var sentence: String {
        switch self {
        case .idle: return ""
        case .asking: return "Asking the PC…"
        case .faceID: return "Face ID required"
        case .authorizing: return "Authorizing…"
        case .signingIn: return "Windows is signing in…"
        case .desktopStarting: return "Signed in. Starting JARVIS…"
        case .online: return "PC-PRIME online"
        case .stopped(let stop): return stop.sentence
        }
    }
}

/// Why an unlock stopped.
///
/// Separate from a plain message because the caller needs to know two things a sentence cannot
/// carry: whether the owner simply declined - in which case nothing is wrong and nothing should
/// be reported as wrong - and whether trying again could possibly help.
enum UnlockStop: Equatable {
    case cancelled
    case biometryUnavailable
    case biometryNotEnrolled
    case biometryLockedOut
    case faceNotRecognised

    case notPaired
    case serviceUnreachable
    case notConfigured
    case alreadyInUse

    case challenge(UnlockChallenge.Fault)

    /// The PC refused the authorization, in its own words.
    case refused(String)

    /// The authorization was good and the stored Windows credential is not usable.
    case needsReEnrolment(String)

    /// Windows was authorized and the session never changed. Said as the uncertainty it is.
    case neverSignedIn

    /// Signed in; desktop JARVIS did not come up within the time allowed.
    case desktopDidNotStart

    /// The owner declined. Not a failure, and not shown as one.
    var isCancellation: Bool { self == .cancelled }

    /// Whether pressing it again could plausibly do something different.
    var worthRetrying: Bool {
        switch self {
        case .cancelled, .serviceUnreachable, .challenge, .neverSignedIn, .desktopDidNotStart:
            return true
        case .biometryUnavailable, .biometryNotEnrolled, .biometryLockedOut, .faceNotRecognised:
            return true
        case .notPaired, .notConfigured, .alreadyInUse, .needsReEnrolment, .refused:
            return false
        }
    }

    var sentence: String {
        switch self {
        case .cancelled:
            return "Cancelled."
        case .biometryUnavailable:
            return "Face ID isn't available on this phone, so it can't authorize an unlock."
        case .biometryNotEnrolled:
            return "Face ID isn't set up on this phone yet. Set it up to unlock your PC from here."
        case .biometryLockedOut:
            return "Face ID is locked out. Unlock this phone with your passcode first."
        case .faceNotRecognised:
            return "Face ID didn't recognise you, so nothing was sent."
        case .notPaired:
            return "This phone isn't paired with the PC's sign-in service yet."
        case .serviceUnreachable:
            return "The PC's sign-in service isn't answering."
        case .notConfigured:
            return "This PC isn't set up to be unlocked from a phone."
        case .alreadyInUse:
            return "Your PC is already in use."
        case .challenge(let fault):
            return fault.sentence
        case .refused(let because):
            return because
        case .needsReEnrolment(let because):
            return "Your phone approved it, but this PC's saved Windows credential needs enrolling again. \(because)"
        case .neverSignedIn:
            return "Your PC accepted the authorization, but Windows hasn't signed in. Your PIN still works."
        case .desktopDidNotStart:
            return "Windows signed in, but JARVIS on the PC hasn't connected yet."
        }
    }
}

/// Whether the PC could be signed in from here, as the service reports it.
///
/// `unknown` is a service too old to say, and is treated as "try and find out" rather than as a
/// refusal: a phone that stopped offering unlock because the PC had not learned to describe
/// itself would be a worse bug than one that offers it and is told no.
enum UnlockReadiness: String, Equatable {
    case ready
    case needsReEnrolment
    case notEnrolled
    case unsupported
    case unknown

    var couldWork: Bool {
        switch self {
        case .ready, .unknown: return true
        case .needsReEnrolment, .notEnrolled, .unsupported: return false
        }
    }

    /// Why not, when not. Nil when an unlock is worth offering.
    var obstacle: String? {
        switch self {
        case .ready, .unknown: return nil
        case .needsReEnrolment: return "This PC's saved Windows credential needs enrolling again."
        case .notEnrolled: return "No Windows credential is enrolled on this PC yet."
        case .unsupported: return "This PC isn't set up to be unlocked from a phone."
        }
    }
}

/// What the phone should offer for the PC right now.
///
/// Derived rather than stored, so it cannot disagree with the machine's last report. The rule the
/// brief asks for - do not offer an unlock when it cannot work - is one `switch` rather than
/// scattered `if`s in a view, which is how a button comes back in one place after being hidden in
/// another.
enum PCAvailability: Equatable {
    case notPaired
    case unreachable
    case locked
    case nobodySignedIn
    case inUse
    case online

    /// Whether UNLOCK PC belongs on screen at all.
    var offersUnlock: Bool {
        switch self {
        case .locked, .nobodySignedIn: return true
        case .notPaired, .unreachable, .inUse, .online: return false
        }
    }

    var headline: String {
        switch self {
        case .notPaired: return "Not paired"
        case .unreachable: return "PC off"
        case .locked: return "Windows locked"
        case .nobodySignedIn: return "On, nobody signed in"
        case .inUse: return "In use"
        case .online: return "PC-PRIME online"
        }
    }

    /// Reads it from what the service last said.
    static func of(_ report: MachineReport?, paired: Bool) -> PCAvailability {
        guard paired else { return .notPaired }
        guard let report else { return .unreachable }

        switch report.session {
        case .inUse: return report.desktopRunning ? .online : .inUse
        case .locked: return .locked
        case .nobodySignedIn: return .nobodySignedIn
        case .unknown: return .unreachable
        }
    }
}


/// Where the PC stands, and whether to offer to sign into it.
///
/// Two facts rather than one, because they fail independently: a locked PC with no credential
/// enrolled and an unreachable PC are both "no unlock button", and showing the same thing for
/// both is how somebody spends an evening checking their network. The session says what the
/// machine is doing; the readiness says whether this phone could do anything about it.
struct PCStanding: Equatable {
    let availability: PCAvailability
    let readiness: UnlockReadiness

    static func of(_ report: MachineReport?, paired: Bool) -> PCStanding {
        PCStanding(
            availability: PCAvailability.of(report, paired: paired),
            readiness: report?.unlock ?? .unknown)
    }

    /// Whether UNLOCK PC belongs on screen.
    ///
    /// The brief's list of when not to show it, in one expression: not while the PC is in use,
    /// not while it is unpaired or unreachable, and not while the PC has told us an unlock cannot
    /// presently work.
    var offersUnlock: Bool { availability.offersUnlock && readiness.couldWork }

    var headline: String { availability.headline }

    /// The line under it: why there is no unlock button, when the machine itself is reachable
    /// and the reason is worth knowing. Nil when there is nothing useful to add.
    var obstacle: String? {
        guard availability.offersUnlock else { return nil }
        return readiness.obstacle
    }
}
