import XCTest
@testable import JARVIS

/// What Mobile JARVIS says about itself - programme §4, §54 and §58.
///
/// Two rules every test here is about. "JARVIS is offline" is almost never true, so the panel lists
/// subsystems rather than collapsing them into one word. And nothing dull is said out loud: a
/// status reciting every healthy thing every time would train the owner to stop listening, and
/// then the one that mattered would go past unheard.
final class MobileStatusTests: XCTestCase {
    private func state(
        pcAnswering: Bool = false,
        wake: Bool = false,
        token: Bool = false,
        devices: Int = 0,
        footage: Bool = false,
        location: Bool = false,
        alerts: Bool = false,
        cloud: Bool = false
    ) -> MobileCapabilities.NodeState {
        var state = MobileCapabilities.NodeState()
        state.pcName = "DOM-PC"
        state.pcAnswering = pcAnswering
        state.wakeEnabled = wake
        state.wakeReachable = wake
        state.hasOwnDeviceToken = token
        state.reachableDevices = devices
        state.footageJoined = footage
        state.locationReporting = location
        state.alertsOn = alerts
        state.cloudReady = cloud
        return state
    }

    private func reading(_ name: String, _ percent: Int?, charge: ChargeReading = .discharging) -> PowerReading {
        PowerReading(
            deviceId: name.lowercased(),
            name: name,
            percent: percent,
            charge: charge,
            measuredAt: Date(),
            lowPowerMode: false,
            because: percent == nil ? "iOS doesn't tell apps." : nil)
    }

    private func row(_ id: String, _ rows: [MobileAvailability]) -> MobileAvailability? {
        rows.first { $0.id == id }
    }

    // MARK: The panel - programme §4

    /// This phone is the one node that is always here, because it is the thing being asked.
    func testThisPhoneIsAlwaysOnline() {
        XCTAssertEqual(row("mobile", MobileStatus.availability(state()))?.state.word, "ONLINE")
    }

    /// The central requirement of §54: with the PC off, plenty is still available.
    func testWithThePCOffPlentyIsStillAvailable() {
        let rows = MobileStatus.availability(
            state(token: true, devices: 1, footage: true, location: true, alerts: true, cloud: true))

        XCTAssertEqual(row("pc", rows)?.state.word, "UNAVAILABLE")
        XCTAssertEqual(row("home", rows)?.state.word, "AVAILABLE")
        XCTAssertEqual(row("cloud", rows)?.state.word, "AVAILABLE")
        XCTAssertEqual(row("footage", rows)?.state.word, "AVAILABLE")
        XCTAssertEqual(row("whereabouts", rows)?.state.word, "ONLINE")
        XCTAssertTrue(MobileStatus.anythingUsable(state()), "this phone is always something")
    }

    /// A PC that can be woken says so, because that changes what the owner does next.
    func testAPCThatCanBeWokenSaysSo() {
        let canWake = row("pc", MobileStatus.availability(state(wake: true)))
        XCTAssertTrue(canWake?.state.detail?.contains("woken") == true, "\(canWake?.state.detail ?? "nil")")

        let cannot = row("pc", MobileStatus.availability(state(wake: false)))
        XCTAssertFalse(cannot?.state.detail?.contains("woken") == true)
    }

    /// "Not set up" and "unavailable" are different, and so are their remedies.
    func testNotSetUpIsDistinguishedFromUnavailable() {
        let rows = MobileStatus.availability(state())

        XCTAssertEqual(row("cloud", rows)?.state.word, "NOT SET UP")
        XCTAssertEqual(row("footage", rows)?.state.word, "NOT SET UP")
        XCTAssertEqual(row("pc", rows)?.state.word, "UNAVAILABLE",
                       "a PC that is asleep is not a PC nobody set up")
    }

    /// The smart home's route is named, because the two routes mean different things.
    func testTheSmartHomesRouteIsNamed() {
        XCTAssertEqual(row("home", MobileStatus.availability(state(pcAnswering: true)))?.state.detail,
                       "Through DOM-PC")
        XCTAssertEqual(row("home", MobileStatus.availability(state(token: true, devices: 1)))?.state.detail,
                       "Straight to SwitchBot")
    }

    func testWithoutATokenTheHouseNeedsSettingUpRatherThanBeingUnavailable() {
        let rows = MobileStatus.availability(state(devices: 1))

        XCTAssertEqual(row("home", rows)?.state.word, "NOT SET UP")
        XCTAssertTrue(row("home", rows)?.state.detail?.contains("token") == true)
    }

    func testEveryRowHasATitleAndNoneLeaksASecret() {
        for row in MobileStatus.availability(state(token: true, devices: 1, footage: true)) {
            XCTAssertFalse(row.title.isEmpty, row.id)
            XCTAssertFalse((row.state.detail ?? "").lowercased().contains("token ="), row.id)
            XCTAssertFalse((row.state.detail ?? "").lowercased().contains("error"), row.id)
        }
    }

    // MARK: Spoken status - programme §58

    func testWithEverythingInOrderItSaysSoAndNothingElse() {
        let said = MobileStatus.say(state(pcAnswering: true, token: true, devices: 1),
                                    power: [reading("iPhone", 84)])

        XCTAssertEqual(said.count, 2, said.joined(separator: " | "))
        XCTAssertTrue(said[0].contains("answering"))
        XCTAssertEqual(said[1], MobilePhrases.nothingWantsAttention())
    }

    func testAHealthyBatteryIsNotMentioned() {
        let said = MobileStatus.line(state(pcAnswering: true, token: true, devices: 1),
                                     power: [reading("iPhone", 84), reading("AirPods Pro", nil)])

        XCTAssertFalse(said.contains("84"))
        XCTAssertFalse(said.contains("AirPods"))
    }

    func testALowBatteryIsMentioned() {
        let said = MobileStatus.line(state(pcAnswering: true, token: true, devices: 1),
                                     power: [reading("iPhone", 12)])

        XCTAssertTrue(said.contains("iPhone"), said)
        XCTAssertTrue(said.contains("12"), said)
    }

    /// Something low and on charge is not a problem, and saying so is the warning owners learn to
    /// ignore.
    func testALowBatteryOnChargeIsNotAWarning() {
        for charge in [ChargeReading.charging, .full] {
            let said = MobileStatus.line(state(pcAnswering: true, token: true, devices: 1),
                                         power: [reading("iPhone", 8, charge: charge)])

            XCTAssertFalse(said.contains("iPhone"), "\(charge): \(said)")
        }
    }

    func testAPCThatIsNotAnsweringIsTheFirstThingSaid() {
        let said = MobileStatus.say(state(wake: true, token: true, devices: 1))

        XCTAssertTrue(said[0].contains("DOM-PC"))
        XCTAssertTrue(said[0].contains("wake"), said[0])
    }

    func testAHouseThatCannotBeReachedIsSaid() {
        let said = MobileStatus.line(state(pcAnswering: false))

        XCTAssertTrue(said.contains("Nothing in the house"), said)
    }

    func testSomethingWaitingToSyncIsSaidAndWorkingSyncIsNot() {
        let ready = state(pcAnswering: true, token: true, devices: 1)

        XCTAssertTrue(MobileStatus.line(ready, queued: 14).contains("waiting"))
        XCTAssertTrue(MobileStatus.line(ready, behind: 40).contains("catching up"))

        let level = MobileStatus.line(ready)
        XCTAssertFalse(level.contains("waiting"))
        XCTAssertFalse(level.contains("catching up"))
    }

    /// A queue is the more pressing of the two, so only one is said.
    func testAQueueIsSaidRatherThanBoth() {
        let said = MobileStatus.line(state(pcAnswering: true, token: true, devices: 1), queued: 14, behind: 40)

        XCTAssertTrue(said.contains("waiting"))
        XCTAssertFalse(said.contains("catching up"))
    }

    func testEvenAtItsBusiestItStaysShort() {
        let busy = state(wake: true)
        let said = MobileStatus.say(busy, power: [reading("iPhone", 9)], queued: 7)

        XCTAssertLessThanOrEqual(said.count, 5)
        XCTAssertTrue(said.joined(separator: " ").contains("sir"))
    }

    // MARK: Being asked for it

    func testAskingForStatusIsRecognisedWithoutNamingAMachine() {
        for sentence in ["status", "jarvis status", "report", "is everything all right",
                         "is everything okay", "anything wrong", "how are things"] {
            XCTAssertEqual(LocalCapability.of(sentence), .status, sentence)
        }
    }

    /// Naming a machine is a question about the machine, which the other rule answers better.
    func testAskingAboutThePCInParticularIsNotTheWholeStatus() {
        XCTAssertEqual(LocalCapability.of("what's my pc's status"), .state(target: nil))
        XCTAssertEqual(LocalCapability.of("is my pc on"), .state(target: nil))
    }

    func testStatusIsNotADeviceCommand() {
        XCTAssertFalse(LocalCapability.status.isADeviceCommand)
        XCTAssertEqual(LocalCapability.status.action, "node.status")
        XCTAssertNil(LocalCapability.status.target)
    }

    /// With the PC up, the PC answers it: it can see every node's readings and this phone cannot.
    func testWithThePCAnsweringTheStatusGoesToThePCWithThisPhoneAsTheFallback() {
        var up = state(pcAnswering: true)
        up.pcName = "DOM-PC"

        let decision = MobileCapabilities.decide("status", devices: [], state: up)

        XCTAssertEqual(decision.lane, .pcPrime)
        guard case .localMobile(.status) = decision.fallback else {
            return XCTFail("the status should fall back to this phone: \(String(describing: decision.fallback))")
        }
    }

    func testSentinel() {}
}
