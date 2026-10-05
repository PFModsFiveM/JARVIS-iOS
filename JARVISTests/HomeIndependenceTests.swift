import XCTest
@testable import JARVIS

/// The commissioning diagnostic - programme §2.
///
/// The property every test here is about: when the light will not work, the page names the one
/// thing in the chain that is wrong, and names it in the order the chain runs. Telling the owner
/// the hub is unreachable when the real problem is a missing token would be worse than saying
/// nothing, because they would go and look at the hub.
final class HomeIndependenceTests: XCTestCase {
    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    private var hue: StandbyDevice {
        StandbyDevice([
            "id": "hall", "name": "Hall", "kind": "light",
            "provider": "Hue", "providerDeviceId": "1", "preferPress": false
        ])!
    }

    private var token: SwitchBotCredentials { SwitchBotCredentials(token: "t", secret: "s") }

    private static let noon = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: The chain, in order

    func testWithNoTokenTheBlockerIsTheCredential() {
        let report = HomeIndependence.read(credentials: nil, bindings: [light], pcAnswering: false)

        XCTAssertEqual(report.blocker, .credential)
        XCTAssertEqual(report.credentials.word, "NO")
        XCTAssertEqual(report.routeNow, .unavailable(report.directRoute.detail!))
        XCTAssertFalse(report.workable)
    }

    func testWithATokenAndNoBindingTheBlockerIsTheBinding() {
        let report = HomeIndependence.read(credentials: token, bindings: [], pcAnswering: false)

        XCTAssertEqual(report.blocker, .binding)
        XCTAssertEqual(report.credentials.word, "YES")
        XCTAssertEqual(report.bindings.word, "NO")
    }

    /// A provider this phone cannot talk to is a routing problem, not a broken hub.
    func testAProviderThisPhoneCannotReachIsARoutingProblem() {
        let report = HomeIndependence.read(credentials: token, bindings: [hue], pcAnswering: false)

        XCTAssertEqual(report.blocker, .routing)
        XCTAssertEqual(report.directRoute.word, "NO")
        XCTAssertTrue(report.directRoute.detail!.contains("Hue"))
    }

    func testNoConnectionIsTheNetworkAndNotTheVendor() {
        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false, networkUp: false)

        XCTAssertEqual(report.blocker, .network)
    }

    /// Everything configured and nothing asked yet: no blocker, and the hub honestly unknown.
    func testEverythingInPlaceAndNothingAskedYetIsNotABlocker() {
        let report = HomeIndependence.read(credentials: token, bindings: [light], pcAnswering: false)

        XCTAssertNil(report.blocker)
        XCTAssertEqual(report.directRoute.word, "YES")
        XCTAssertEqual(report.routeNow, .mobileDirect)
        XCTAssertEqual(report.hub.word, "UNKNOWN")
        XCTAssertTrue(report.workable)
    }

    /// With the PC answering there is a route whatever else is missing, so nothing is blocking
    /// control - only independence, which the lines report on their own.
    func testWithThePcAnsweringNothingIsBlockingControl() {
        let report = HomeIndependence.read(credentials: nil, bindings: [], pcAnswering: true)

        XCTAssertNil(report.blocker)
        XCTAssertEqual(report.routeNow, .pc)
        XCTAssertEqual(report.pcRoute.word, "YES")
        XCTAssertEqual(report.credentials.word, "NO", "still reported, because independence is not control")
    }

    // MARK: What a probe establishes

    private func probe(_ outcome: StandbyOutcome, battery: Int? = nil) -> HomeIndependence.Probe {
        HomeIndependence.Probe(at: Self.noon, outcome: outcome, device: "Bedroom Light", battery: battery)
    }

    /// The only thing that can turn "unknown" into "yes" for the hub.
    func testAConfirmedReadProvesTheWholeChain() {
        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false, probe: probe(.confirmed(on: true), battery: 88))

        XCTAssertNil(report.blocker)
        XCTAssertEqual(report.hub.word, "YES")
    }

    func testAnOfflineHubIsSaidAsTheHubAndNotTheDevice() {
        let outcome = StandbyOutcome.offline(
            "The SwitchBot Hub isn't online, so the command couldn't be relayed. If it's powered from the PC's USB, it will be off too.")

        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false, probe: probe(outcome))

        XCTAssertEqual(report.blocker, .hub)
        XCTAssertEqual(report.hub.word, "NO")
        XCTAssertTrue(HomeBlocker.hub.remedy.contains("USB"), "the remedy names the likely cause")
    }

    func testADeviceThatIsNotAnsweringItsHubIsSaidAsTheDevice() {
        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false,
            probe: probe(.offline("The device isn't answering the hub.")))

        XCTAssertEqual(report.blocker, .device)
        XCTAssertEqual(report.hub.word, "YES", "the hub answered; the device did not")
    }

    func testARefusedTokenIsTheAccount() {
        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false,
            probe: probe(.failed("SwitchBot didn't accept the token on this phone. Check it in Settings.")))

        XCTAssertEqual(report.blocker, .vendor)
    }

    /// A command that went through and could not be read back is its own answer, and it is not
    /// "the light is broken".
    func testSomethingSentButUnreadIsTheConfirmationAndNothingElse() {
        XCTAssertEqual(probe(.sent).blocker, .confirmation)
        XCTAssertEqual(probe(.ambiguous("I sent it, but SwitchBot stopped answering.")).blocker, .confirmation)
    }

    func testNoConnectionDuringAProbeIsTheNetwork() {
        XCTAssertEqual(probe(.unavailable("This phone has no connection.")).blocker, .network)
    }

    // MARK: What the page must never show

    /// A diagnostic page is exactly the sort of screen somebody photographs to ask for help with.
    func testNoTokenOrSecretIsAnywhereInTheReport() {
        let report = HomeIndependence.read(
            credentials: SwitchBotCredentials(token: "SECRETTOKEN", secret: "SECRETSECRET"),
            bindings: [light],
            pcAnswering: false,
            probe: probe(.confirmed(on: true)))

        let printed = [
            report.credentials.detail, report.bindings.detail, report.device.detail,
            report.directRoute.detail, report.pcRoute.detail, report.hub.detail,
            report.lastResult, report.lastConfirmedState, String(describing: report.routeNow)
        ].compactMap { $0 }.joined(separator: " ")

        XCTAssertFalse(printed.contains("SECRETTOKEN"))
        XCTAssertFalse(printed.contains("SECRETSECRET"))

        // And not the vendor's own device id either, which says which switch is which in a house.
        XCTAssertFalse(printed.contains("C271D2A08E4F"))
    }

    func testEveryBlockerHasARemedyWorthReading() {
        for blocker in HomeBlocker.allCases {
            XCTAssertFalse(blocker.title.isEmpty, "\(blocker)")
            XCTAssertTrue(blocker.remedy.count > 30, "\(blocker) should say what to do about it")
            XCTAssertFalse(blocker.remedy.lowercased().contains("error"), "\(blocker)")
        }
    }

    func testTheLastCommandIsCarriedThroughForThePageToShow() {
        let report = HomeIndependence.read(
            credentials: token, bindings: [light], pcAnswering: false,
            lastCommandAt: Self.noon, lastResult: "Confirmed off.", lastConfirmedState: "Off")

        XCTAssertEqual(report.lastCommandAt, Self.noon)
        XCTAssertEqual(report.lastResult, "Confirmed off.")
        XCTAssertEqual(report.lastConfirmedState, "Off")
    }

    func testSentinel() {}
}
