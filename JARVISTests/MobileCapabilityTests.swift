import XCTest
@testable import JARVIS

/// Mobile JARVIS as a node: what it says it can do, and where a request goes.
///
/// `LocalCapabilityTests` covers the reading of the sentences. These cover the decision made with
/// that reading - which is the thing that was missing a case. A request belonging to PC-Prime with
/// PC-Prime off was sent anyway and came back as a transport error, so the phone said "Connection
/// refused" where JARVIS would have said which machine does that and what it could offer instead.
final class MobileCapabilityTests: XCTestCase {

    private func state(
        pcAnswering: Bool = false,
        servicePaired: Bool = false,
        wakeEnabled: Bool = false,
        wakeReachable: Bool = false,
        token: Bool = false,
        devices: Int = 0,
        footage: Bool = false,
        location: Bool = false,
        alerts: Bool = false
    ) -> MobileCapabilities.NodeState {
        MobileCapabilities.NodeState(
            pcName: "DOM-PC",
            pcAnswering: pcAnswering,
            servicePaired: servicePaired,
            wakeEnabled: wakeEnabled,
            wakeReachable: wakeReachable,
            hasOwnDeviceToken: token,
            reachableDevices: devices,
            footageJoined: footage,
            locationReporting: location,
            alertsOn: alerts)
    }

    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    // MARK: Routing

    /// Everything goes to the PC while the PC is answering, including the three requests this
    /// phone could handle itself. It understands the sentence better and owns the device state.
    func testAnAnsweringPCGetsEverything() {
        let up = state(pcAnswering: true, wakeEnabled: true, wakeReachable: true, token: true, devices: 1)

        for said in ["wake my pc", "is my pc on", "turn the bedroom light on", "what's the weather"] {
            XCTAssertEqual(MobileCapabilities.route(said, devices: [light], state: up), .pcPrime,
                           "\(said) should have gone to the PC")
        }
    }

    func testWithThePCOffTheRequestsThisPhoneCanAnswerStayHere() {
        let off = state(wakeEnabled: true, wakeReachable: true, token: true, devices: 1)

        guard case .thisPhone(.wake) = MobileCapabilities.route("wake my pc", devices: [light], state: off) else {
            return XCTFail("waking should be this phone's")
        }
        guard case .thisPhone(.state) = MobileCapabilities.route("is my pc on", devices: [light], state: off) else {
            return XCTFail("the machine's state should be this phone's")
        }
        guard case .thisPhone(.device(let id, let command)) =
                MobileCapabilities.route("turn the bedroom light on", devices: [light], state: off) else {
            return XCTFail("a light this phone can reach should be this phone's")
        }
        XCTAssertEqual(id, "bedroom_main_light")
        XCTAssertEqual(command, .on)
    }

    /// The case that was missing. Not an error, not a guess at the answer, and not silence.
    func testARequestForThePCWithThePCOffIsAnsweredRatherThanSent() {
        guard case .waitingForThePC(let because) =
                MobileCapabilities.route("what's on my calendar", devices: [light], state: state()) else {
            return XCTFail("should have been answered here rather than sent")
        }

        XCTAssertTrue(because.contains("DOM-PC"), "the answer should name the machine: \(because)")
        XCTAssertFalse(because.lowercased().contains("error"))
        XCTAssertFalse(because.lowercased().contains("refused"))
    }

    /// What it offers depends on what this phone can actually do about it.
    func testTheAnswerOffersAWakeOnlyWhenAWakeWouldWork() {
        let canWake = MobileCapabilities.waiting(state(wakeEnabled: true, wakeReachable: true))
        XCTAssertTrue(canWake.lowercased().contains("wake my pc"), canWake)

        let cannot = MobileCapabilities.waiting(state(wakeEnabled: false))
        XCTAssertFalse(cannot.lowercased().contains("say \u{201C}wake my pc\u{201D}"), cannot)
    }

    /// Never a claim that something happened. §"Never falsely claim physical confirmation."
    func testTheAnswerNeverClaimsItDidTheThing() {
        for one in [state(), state(wakeEnabled: true, wakeReachable: true), state(servicePaired: true)] {
            let said = MobileCapabilities.waiting(one).lowercased()
            XCTAssertFalse(said.contains("done"), said)
            XCTAssertFalse(said.contains("i've "), said)
        }
    }

    // MARK: The declaration

    func testEveryCardIsNamedOnceAndSaysSomething() {
        let cards = MobileCapabilities.cards(state())
        XCTAssertEqual(cards.count, Set(cards.map(\.id)).count, "two cards share an id")

        for card in cards {
            XCTAssertFalse(card.title.isEmpty)
            XCTAssertFalse(card.detail.isEmpty, "\(card.id) has no explanation")
            XCTAssertFalse(card.symbol.isEmpty)
        }
    }

    func testBothNodesAreDeclared() {
        let cards = MobileCapabilities.cards(state())
        XCTAssertTrue(cards.contains { $0.node == .thisPhone })
        XCTAssertTrue(cards.contains { $0.node == .pcPrime },
                      "a node that does not know what the other node does cannot explain itself")
    }

    /// A phone with nothing set up should not claim it can do things with the PC off. Speaking is
    /// the one that needs nothing, and it is the only one.
    func testAPhoneWithNothingSetUpClaimsOnlyWhatNeedsNothing() {
        let bare = MobileCapabilities.standalone(state()).map(\.id)
        XCTAssertEqual(bare, ["speak"])
    }

    func testEverythingSetUpIsUsableWithThePCOff() {
        let ready = state(servicePaired: true, wakeEnabled: true, wakeReachable: true,
                          token: true, devices: 2, footage: true, location: true, alerts: true)

        let standalone = Set(MobileCapabilities.standalone(ready).map(\.id))
        XCTAssertEqual(standalone, ["wake", "state", "devices", "footage", "whereabouts", "alerts", "speak"])
    }

    /// PC-Prime's own capabilities are never "works with the PC off", whatever this phone has set up.
    func testThePCsCapabilitiesAreNeverClaimedAsStandalone() {
        let ready = state(pcAnswering: true, servicePaired: true, wakeEnabled: true, wakeReachable: true,
                          token: true, devices: 2, footage: true, location: true, alerts: true)

        for card in MobileCapabilities.cards(ready) where card.node == .pcPrime {
            XCTAssertNotEqual(card.readiness, .standalone, "\(card.id) is not this phone's to do")
            XCTAssertEqual(card.readiness, .throughThePC)
        }
    }

    func testThePCsCapabilitiesWaitWhenThePCIsOff() {
        for card in MobileCapabilities.cards(state()) where card.node == .pcPrime {
            XCTAssertEqual(card.readiness, .waitingForThePC)
        }
    }

    // MARK: What is missing, said precisely

    /// A token with no bindings and bindings with no token both leave the light unreachable, for
    /// different reasons and with different remedies. "Not configured" would serve neither.
    func testTheTwoWaysALightCanBeUnreachableAreToldApart() {
        func needs(_ state: MobileCapabilities.NodeState) -> String? {
            guard case .needs(let what) = MobileCapabilities.cards(state).first(where: { $0.id == "devices" })?.readiness
            else { return nil }
            return what
        }

        let noToken = needs(state(token: false, devices: 2))
        let noBindings = needs(state(token: true, devices: 0))
        let neither = needs(state(token: false, devices: 0))

        XCTAssertNotNil(noToken)
        XCTAssertNotNil(noBindings)
        XCTAssertNotNil(neither)
        XCTAssertNotEqual(noToken, noBindings)
        XCTAssertTrue(noToken?.lowercased().contains("token") == true, noToken ?? "")
        XCTAssertTrue(noBindings?.lowercased().contains("connect") == true, noBindings ?? "")
    }

    func testWakingSaysWhichOfItsTwoRequirementsIsMissing() {
        func needs(_ state: MobileCapabilities.NodeState) -> String? {
            guard case .needs(let what) = MobileCapabilities.cards(state).first(where: { $0.id == "wake" })?.readiness
            else { return nil }
            return what
        }

        XCTAssertTrue(needs(state(wakeEnabled: false, wakeReachable: true))?.contains("Wake-on-LAN") == true)
        XCTAssertTrue(needs(state(wakeEnabled: true, wakeReachable: false))?.contains("network card") == true)
        XCTAssertNil(needs(state(wakeEnabled: true, wakeReachable: true)))
    }

    /// Every card that is not usable says what it is waiting for, so no row is a dead end.
    func testNothingUnusableIsLeftWithoutAnExplanation() {
        for card in MobileCapabilities.cards(state()) where !card.readiness.usable {
            switch card.readiness {
            case .needs(let what): XCTAssertFalse(what.isEmpty, "\(card.id)")
            case .waitingForThePC: XCTAssertEqual(card.node, .pcPrime, "\(card.id)")
            default: XCTFail("\(card.id) is unusable and says nothing")
            }
        }
    }

    func testThePCsNameIsUsedRatherThanThePC() {
        let cards = MobileCapabilities.cards(state())
        XCTAssertTrue(cards.contains { $0.title.contains("DOM-PC") },
                      "the machine should be called by its name where it is named")
    }
}
