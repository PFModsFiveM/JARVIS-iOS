import XCTest
@testable import JARVIS

/// When falling back to the direct route is safe, and when it would undo the request - §7B.
///
/// The failure this prevents is subtle and the owner would never diagnose it: they ask for the
/// lamp to be switched, the PC gets it, the reply is lost, the phone "helpfully" sends the same
/// thing straight to SwitchBot, and the lamp ends up exactly where it started.
final class FallbackSafetyTests: XCTestCase {
    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    // MARK: nothing left, so anything may be tried

    func testARequestThatNeverLeftMayAlwaysBeRetried() {
        for command in [StandbyCommand.on, .off, .press] {
            let lane = MobileCapabilities.MobileLane.directDevice(.device(id: "x", command: command))

            XCTAssertTrue(
                MobileCapabilities.mayFallBack(to: lane, after: .neverSent), "\(command)")
        }

        XCTAssertTrue(MobileCapabilities.mayFallBack(
            to: .directDevice(.deviceToggle(id: "x")), after: .neverSent))
    }

    // MARK: it may have happened

    func testAnExplicitOnOrOffIsSafeToRepeatBecauseArrivingTwiceAtOnIsStillOn() {
        XCTAssertTrue(MobileCapabilities.mayFallBack(
            to: .directDevice(.device(id: "x", command: .on)), after: .unknown))

        XCTAssertTrue(MobileCapabilities.mayFallBack(
            to: .directDevice(.device(id: "x", command: .off)), after: .unknown))
    }

    /// The case the whole rule exists for.
    func testAPressIsNotRepeatedBecauseItWouldMoveAPhysicalRockerTwice() {
        XCTAssertFalse(MobileCapabilities.mayFallBack(
            to: .directDevice(.device(id: "x", command: .press)), after: .unknown))
    }

    func testAToggleIsNeverRepeatedBecauseItIsNeverIdempotent() {
        XCTAssertFalse(MobileCapabilities.mayFallBack(
            to: .directDevice(.deviceToggle(id: "x")), after: .unknown))
    }

    /// A question asked twice costs a moment and changes nothing.
    func testSomethingThatChangesNothingMayAlwaysBeRetried() {
        XCTAssertTrue(MobileCapabilities.mayFallBack(to: .localMobile(.status), after: .unknown))
        XCTAssertTrue(MobileCapabilities.mayFallBack(to: .localMobile(.power(target: nil)), after: .unknown))
        XCTAssertTrue(MobileCapabilities.mayFallBack(
            to: .localMobile(.whereabouts(asked: .whereAmI, named: nil)), after: .unknown))
        XCTAssertTrue(MobileCapabilities.mayFallBack(to: .cloud, after: .unknown))
    }

    // MARK: what the owner is told

    func testRefusingTheFallbackSaysItMayHaveHappenedRatherThanClaimingEitherWay() {
        let said = MobileCapabilities.mayHaveHappened("Bedroom Light")

        XCTAssertTrue(said.contains("may have gone through"))
        XCTAssertTrue(said.contains("won't send it again"))
        XCTAssertTrue(said.contains("Bedroom Light"))

        // Never a claim in either direction. The owner can look, which is cheaper than a guess
        // that undoes what they asked for.
        XCTAssertFalse(said.contains("is on"))
        XCTAssertFalse(said.contains("is off"))
        XCTAssertFalse(said.contains("Done"))
    }

    // MARK: and the routing it sits behind is unchanged

    func testADeviceCommandStillPrefersThePcWithTheDirectRouteAsItsFallback() {
        var state = MobileCapabilities.NodeState()
        state.pcAnswering = true

        let decision = MobileCapabilities.decide(
            "turn the bedroom light off", devices: [light], state: state)

        XCTAssertEqual(decision.lane, .pcPrime)

        guard case .directDevice(let capability) = decision.fallback else {
            return XCTFail("\(String(describing: decision.fallback))")
        }

        guard case .device(_, let command) = capability else { return XCTFail("\(capability)") }

        // And that fallback is an explicit OFF, so it is one of the safe ones.
        XCTAssertEqual(command, .off)
        XCTAssertTrue(MobileCapabilities.mayFallBack(to: decision.fallback!, after: .unknown))
    }

    /// A sentence with no direction becomes a toggle, which is the unsafe shape.
    func testASentenceWithNoDirectionBecomesTheOneThatCannotBeRepeated() {
        var state = MobileCapabilities.NodeState()
        state.pcAnswering = true

        let decision = MobileCapabilities.decide("switch the bedroom light", devices: [light], state: state)

        guard case .directDevice(let capability) = decision.fallback else {
            return XCTFail("\(String(describing: decision.fallback))")
        }

        guard case .deviceToggle = capability else { return XCTFail("\(capability)") }

        XCTAssertFalse(MobileCapabilities.mayFallBack(to: decision.fallback!, after: .unknown))
    }

    func testSentinel() {}
}
