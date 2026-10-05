import Foundation

/// Where the cloud lane stands, as six distinguishable states - priority §8A.
///
/// The brief's instruction is not to collapse these into "cloud unavailable", and the reason is
/// that each one has a different thing the owner would do about it. No key means add one; a
/// refused key means check it; rate-limited means wait; no network means wait differently; and
/// "it worked a moment ago" means the question was the problem rather than the lane.
enum CloudReadiness: String, Codable, Equatable {
    /// No key on this phone. Nothing has been attempted and nothing can be.
    case notConfigured
    /// A key is here and nothing has been tried with it yet.
    case configured
    /// It answered. The only state in which the lane is actually known to work.
    case reachable
    /// The provider is throttling this key.
    case rateLimited
    /// The provider did not accept the key.
    case authenticationFailed
    /// No route out of the phone at all.
    case offline

    /// Whether it is worth trying right now.
    ///
    /// Rate-limited is worth trying, deliberately - the window passes and the alternative is a
    /// lane that stays off until the app is relaunched. Authentication failure is not, because the
    /// key will not start working on its own and retrying it is how an account gets locked.
    var worthTrying: Bool {
        switch self {
        case .notConfigured, .authenticationFailed: return false
        case .configured, .reachable, .rateLimited, .offline: return true
        }
    }

    /// What the owner reads on the settings screen.
    var title: String {
        switch self {
        case .notConfigured: return "Not set up"
        case .configured: return "Set up, not tried yet"
        case .reachable: return "Working"
        case .rateLimited: return "Rate limited"
        case .authenticationFailed: return "Key refused"
        case .offline: return "No connection"
        }
    }

    /// What they would do about it.
    var detail: String {
        switch self {
        case .notConfigured:
            return "Add a key and I can answer general questions with your PC switched off."
        case .configured:
            return "There is a key here. I haven't needed it yet."
        case .reachable:
            return "The provider answered the last time I asked."
        case .rateLimited:
            return "The provider is throttling this key. It usually passes within a minute."
        case .authenticationFailed:
            return "The provider didn't accept the key. Check or replace it below."
        case .offline:
            return "This phone has no route out. Nothing to do but wait for a connection."
        }
    }
}

/// What the cloud lane has actually done, so a screen can say where it stands - §8A.
///
/// Observable rather than computed on demand, because the question "is my cloud working" cannot be
/// answered without asking the provider, and asking the provider to answer a settings screen would
/// spend the owner's quota on a label. So the state is what the last real attempt found.
@MainActor
final class CloudStatus: ObservableObject {
    static let shared = CloudStatus()

    /// How long a request may take before it is given up on - priority §8B.
    ///
    /// Twenty-five seconds, matching the bridge's own request timeout. Long enough for a model to
    /// think about a real question, short enough that the owner is not left watching a spinner
    /// wondering whether they should have asked the PC instead.
    static let timeout: TimeInterval = 25

    @Published private(set) var readiness: CloudReadiness = .notConfigured

    /// When the last attempt happened, successful or not.
    @Published private(set) var lastAttempt: Date?

    /// When it last actually answered.
    @Published private(set) var lastAnswer: Date?

    /// Why the last attempt failed, in the owner's words. Never a key and never a raw body.
    @Published private(set) var lastProblem: String?

    /// How many questions have been answered since the app started, for the diagnostic.
    @Published private(set) var answered = 0

    /// How many were given up on because they took too long.
    @Published private(set) var timedOut = 0

    /// How many the owner stopped.
    @Published private(set) var cancelled = 0

    /// Notes that a key exists, or has gone.
    func configured(_ present: Bool) {
        if !present {
            readiness = .notConfigured
            lastProblem = nil
            return
        }

        // A key appearing clears a previous refusal: the owner has just changed something, and
        // keeping "key refused" would make the lane look broken when they have fixed it.
        if readiness == .notConfigured || readiness == .authenticationFailed {
            readiness = .configured
            lastProblem = nil
        }
    }

    /// Notes that an answer came back.
    func worked(at moment: Date = Date()) {
        readiness = .reachable
        lastAttempt = moment
        lastAnswer = moment
        lastProblem = nil
        answered += 1
    }

    /// Notes what went wrong, mapped to one of the six states.
    func failed(_ problem: CloudProblem, at moment: Date = Date()) {
        lastAttempt = moment
        lastProblem = problem.errorDescription

        switch problem {
        case .notConfigured:
            readiness = .notConfigured
        case .unreachable:
            readiness = .offline
        case .refused(let why):
            // The words come from the status-code mapping, which already distinguishes a refused
            // key from throttling. Reading them back is less fragile than a second mapping that
            // could disagree with the first.
            if why.contains("rate-limiting") {
                readiness = .rateLimited
            } else if why.contains("didn't accept") {
                readiness = .authenticationFailed
            } else if readiness == .notConfigured {
                readiness = .configured
            }

            // Anything else - a 500, a refusal with no explanation - leaves the state alone. The
            // key is fine and the phone has a route out, so calling it "no connection" would send
            // the owner to check their Wi-Fi over a fault at the provider's end. The problem text
            // says what happened; the lane's standing has not changed.
        case .emptyAnswer:
            // It answered, so the lane works. The answer being useless is a different problem and
            // saying the lane is down would send the owner to check their key for nothing.
            readiness = .reachable
            lastAnswer = moment
        }
    }

    /// Notes that a request ran out of time.
    func ranOut(at moment: Date = Date()) {
        lastAttempt = moment
        timedOut += 1
        lastProblem = "The provider didn't answer within \(Int(CloudStatus.timeout)) seconds."

        // Not an authentication or quota problem, and not necessarily offline either - a slow
        // model is a slow model. Left as it was, so one slow question does not relabel the lane.
        if readiness == .notConfigured { readiness = .configured }
    }

    /// Notes that the owner stopped it - priority §8B.
    func stopped() {
        cancelled += 1
        lastProblem = nil
    }

    func forget() {
        readiness = .notConfigured
        lastAttempt = nil
        lastAnswer = nil
        lastProblem = nil
        answered = 0
        timedOut = 0
        cancelled = 0
    }
}
