import XCTest
@testable import JARVIS

/// The challenge this phone will put the owner's face behind.
///
/// Everything here is about refusing. The success case is one test; the rest are the ways a reply
/// can be wrong, because the next thing that happens to an accepted challenge is a Secure Enclave
/// signature over it, and a signature over something that was not understood is the one mistake
/// this flow must not be able to make.
final class UnlockChallengeTests: XCTestCase {
    /// The same instant the fixtures below are issued at, written the same way they are.
    ///
    /// It was an epoch number, and the number was fourteen hours off the ISO strings beside it -
    /// so a challenge the test called "live" had already been expired for most of a day and
    /// secondsLeft came back as 50430. Derived from the text now, because two spellings of one
    /// moment is two things to keep in agreement and they did not stay in agreement.
    private let now = ISO8601DateFormatter().date(from: "2026-05-29T10:26:40Z")!

    private func reply(
        protocolVersion: Any? = 1,
        challengeId: Any? = "c-1",
        nonce: Any? = "9f2c",
        machineId: Any? = "ADMIN",
        accountSid: Any? = "S-1-5-21-1",
        action: Any? = "Unlock",
        issuedAt: Any? = "2026-05-29T10:26:40.0000000+00:00",
        expiresAt: Any? = "2026-05-29T10:27:10.0000000+00:00"
    ) -> [String: Any] {
        var body: [String: Any] = [:]
        if let protocolVersion { body["protocol"] = protocolVersion }
        if let challengeId { body["challengeId"] = challengeId }
        if let nonce { body["nonce"] = nonce }
        if let machineId { body["machineId"] = machineId }
        if let accountSid { body["accountSid"] = accountSid }
        if let action { body["action"] = action }
        if let issuedAt { body["issuedAt"] = issuedAt }
        if let expiresAt { body["expiresAt"] = expiresAt }
        return body
    }

    private func fault(_ body: [String: Any], machine: String? = "ADMIN") -> UnlockChallenge.Fault? {
        switch UnlockChallenge.read(body, machine: machine, now: now) {
        case .success: return nil
        case .failure(let fault): return fault
        }
    }

    // MARK: the one that works

    func testAWellFormedChallengeIsRead() throws {
        let read = try XCTUnwrap(try? UnlockChallenge.read(reply(), machine: "ADMIN", now: now).get())

        XCTAssertEqual(read.id, "c-1")
        XCTAssertEqual(read.machineId, "ADMIN")
        XCTAssertEqual(read.accountSid, "S-1-5-21-1")
        XCTAssertTrue(read.live(at: now))
        XCTAssertEqual(read.secondsLeft(at: now), 30, accuracy: 0.001)
    }

    /// .NET omits the fractional part when a time lands exactly on a second. A parser that only
    /// accepts the usual shape fails rarely and unreproducibly, which is the worst frequency.
    func testATimeWithNoFractionalSecondsStillParses() {
        let body = reply(issuedAt: "2026-05-29T10:26:40+00:00", expiresAt: "2026-05-29T10:27:10+00:00")

        XCTAssertNil(fault(body))
    }

    // MARK: protocol

    func testADifferentProtocolIsRefusedAndSaysBothNumbers() {
        XCTAssertEqual(fault(reply(protocolVersion: 2)), .wrongProtocol(spoken: 1, heard: 2))
    }

    func testAMissingProtocolIsRefusedBeforeAnythingElseIsJudged() {
        // Even with every other field wrong, the protocol is what comes back: the meaning of the
        // other fields is defined by it.
        let body = reply(protocolVersion: nil, machineId: "SOMEONE-ELSE", action: "StandDown")

        XCTAssertEqual(fault(body), .missing("protocol"))
    }

    // MARK: identity

    func testAChallengeForAnotherMachineIsRefused() {
        XCTAssertEqual(
            fault(reply(machineId: "OTHER-PC")),
            .wrongMachine(expected: "ADMIN", heard: "OTHER-PC"))
    }

    func testAChallengeIsAcceptedWhenThisPhoneDoesNotYetKnowTheMachineName() {
        // First contact: the phone has no report yet. The PC still checks its own name, and this
        // phone has nothing to compare against, so it does not invent a comparison.
        XCTAssertNil(fault(reply(machineId: "ANY-PC"), machine: nil))
    }

    func testAnActionThatIsNotUnlockIsRefused() {
        XCTAssertEqual(fault(reply(action: "StandDown")), .wrongAction("StandDown"))
    }

    func testAMissingAccountIsRefused() {
        XCTAssertEqual(fault(reply(accountSid: nil)), .missing("account"))
    }

    func testABlankFieldCountsAsMissingRatherThanAsAValue() {
        XCTAssertEqual(fault(reply(challengeId: "   ")), .missing("challenge id"))
    }

    func testAMissingNonceIsRefused() {
        XCTAssertEqual(fault(reply(nonce: nil)), .missing("nonce"))
    }

    // MARK: the window

    func testAChallengeThatHasAlreadyExpiredIsRefused() {
        let body = reply(issuedAt: "2026-05-29T10:20:00.0000000+00:00",
                         expiresAt: "2026-05-29T10:20:30.0000000+00:00")

        XCTAssertEqual(fault(body), .alreadyExpired)
    }

    func testAWindowThatEndsBeforeItStartsIsRefused() {
        let body = reply(issuedAt: "2026-05-29T10:27:10.0000000+00:00",
                         expiresAt: "2026-05-29T10:26:40.0000000+00:00")

        XCTAssertEqual(fault(body), .impossibleWindow)
    }

    func testAnUnreadableTimeIsRefusedRatherThanTreatedAsNow() {
        XCTAssertEqual(fault(reply(expiresAt: "soon")), .missing("expiry"))
    }

    // MARK: what the owner is told

    func testEveryFaultSaysSomethingUseful() {
        let faults: [UnlockChallenge.Fault] = [
            .notAChallenge("The PC refused."),
            .missing("nonce"),
            .wrongProtocol(spoken: 1, heard: 9),
            .wrongAction("StandDown"),
            .wrongMachine(expected: "ADMIN", heard: "OTHER"),
            .impossibleWindow,
            .alreadyExpired
        ]

        for fault in faults {
            XCTAssertFalse(fault.sentence.isEmpty, "\(fault) had nothing to say")
            XCTAssertFalse(fault.sentence.contains("Optional("), "\(fault) leaked a Swift description")
        }
    }

    func testTheProtocolFaultNamesBothSidesSoItIsActionable() {
        let said = UnlockChallenge.Fault.wrongProtocol(spoken: 1, heard: 4).sentence

        XCTAssertTrue(said.contains("4"))
        XCTAssertTrue(said.contains("1"))
    }
}
