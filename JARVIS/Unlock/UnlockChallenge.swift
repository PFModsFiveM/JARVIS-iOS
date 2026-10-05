import Foundation

/// A challenge the PC issued, after it has been checked rather than merely decoded.
///
/// This type cannot hold a challenge that failed a check. There is no initialiser that skips
/// `read`, and `read` returns a fault instead of a value for every way the reply can be wrong.
/// That is the point: the next thing that happens to a challenge is the owner's face being used
/// to sign it, and signing something that was not understood is the one mistake this flow must
/// not be able to make.
///
/// The PC's half of this is `UnlockChallengeStore` and `UnlockChallenge` in
/// `Jarvis.Core/Security/Unlock/UnlockAuthorization.cs`. Both sides check the same six things
/// about the same challenge, because a check that only one end performs is a check an attacker
/// performs from the other end.
struct UnlockChallenge: Equatable {
    /// What this phone speaks. The PC refuses anything else, and so does this.
    static let protocolSpoken = 1

    /// The only action this phone will sign. The field exists so that a future action cannot be
    /// slipped into an unlock by a PC that has been tampered with or a build that has drifted.
    static let actionExpected = "Unlock"

    let id: String
    let nonce: String
    let machineId: String
    let accountSid: String
    let issuedAt: Date
    let expiresAt: Date

    func live(at now: Date) -> Bool { now < expiresAt }

    func secondsLeft(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    /// Why a reply was not a challenge this phone will sign.
    ///
    /// Each case names the thing that was wrong rather than saying the reply was bad, because
    /// these are the only evidence anybody gets when an unlock will not start, and "malformed"
    /// sends somebody to read a packet capture.
    enum Fault: Equatable {
        /// Not a challenge at all - the PC refused, or answered something else entirely.
        case notAChallenge(String)

        /// A field that must be there and was not, or was blank.
        case missing(String)

        case wrongProtocol(spoken: Int, heard: Int)
        case wrongAction(String)
        case wrongMachine(expected: String, heard: String)

        /// Issued and expiring at times that cannot both be true.
        case impossibleWindow

        /// It arrived already dead. Different from expiring later, which is the ordinary race.
        case alreadyExpired

        var sentence: String {
            switch self {
            case .notAChallenge(let what):
                return what
            case .missing(let field):
                return "The PC's challenge had no \(field)."
            case .wrongProtocol(let spoken, let heard):
                return "This PC speaks unlock protocol \(heard); this phone speaks \(spoken). One of them needs updating."
            case .wrongAction(let action):
                return "That authorization was for \(action), not for unlocking."
            case .wrongMachine(let expected, let heard):
                return "That challenge is for \(heard), and this phone is paired with \(expected)."
            case .impossibleWindow:
                return "The PC's challenge expires before it was issued."
            case .alreadyExpired:
                return "That challenge had already expired when it arrived."
            }
        }
    }

    /// Reads and checks a `unlock.challenge` reply.
    ///
    /// `machine` is the name this phone believes it is paired with, when it knows one. A challenge
    /// naming a different machine is refused rather than signed: the signature binds to whatever
    /// the challenge says, so a challenge from the wrong machine is a signature for the wrong
    /// machine.
    static func read(
        _ body: [String: Any],
        machine expected: String?,
        now: Date = Date()
    ) -> Result<UnlockChallenge, Fault> {
        func text(_ key: String) -> String? {
            guard let value = body[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }

        // The protocol first. Every other field's meaning is defined by it, so checking the
        // meaning of a field before knowing the dialect is checking nothing.
        guard let heardProtocol = body["protocol"] as? Int else { return .failure(.missing("protocol")) }

        guard heardProtocol == protocolSpoken else {
            return .failure(.wrongProtocol(spoken: protocolSpoken, heard: heardProtocol))
        }

        guard let id = text("challengeId") else { return .failure(.missing("challenge id")) }
        guard let nonce = text("nonce") else { return .failure(.missing("nonce")) }
        guard let machineId = text("machineId") else { return .failure(.missing("machine")) }
        guard let accountSid = text("accountSid") else { return .failure(.missing("account")) }
        guard let action = text("action") else { return .failure(.missing("action")) }

        guard action == actionExpected else { return .failure(.wrongAction(action)) }

        if let expected, !expected.isEmpty, machineId != expected {
            return .failure(.wrongMachine(expected: expected, heard: machineId))
        }

        guard let issuedText = text("issuedAt"), let issuedAt = moment(issuedText) else {
            return .failure(.missing("issued time"))
        }

        guard let expiresText = text("expiresAt"), let expiresAt = moment(expiresText) else {
            return .failure(.missing("expiry"))
        }

        guard expiresAt > issuedAt else { return .failure(.impossibleWindow) }
        guard expiresAt > now else { return .failure(.alreadyExpired) }

        return .success(UnlockChallenge(
            id: id, nonce: nonce, machineId: machineId, accountSid: accountSid,
            issuedAt: issuedAt, expiresAt: expiresAt))
    }

    /// Reads the PC's timestamps.
    ///
    /// .NET writes a `DateTimeOffset` as ISO-8601 with fractional seconds and an offset; a value
    /// that lands exactly on a second has no fractional part at all. Both are tried, in that
    /// order, because a parser that only accepts the common shape fails roughly once a second's
    /// worth of the time and is miserable to diagnose.
    private static func moment(_ text: String) -> Date? {
        if let date = withFraction.date(from: text) { return date }
        return whole.date(from: text)
    }

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
