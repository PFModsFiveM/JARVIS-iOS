import Network
import XCTest
@testable import JARVIS

/// Waking the PC while it is asleep, and the one thing this is careful never to claim.
///
/// Wake-on-LAN is out of band on purpose: it works while the PC is off, so nothing here may depend
/// on JARVIS running, on the bridge being connected or on anybody being logged in. Sending is the
/// whole of what it does, and "sent" is the whole of what it reports.
///
/// Nothing here puts a packet on a network: the send is a seam, so these prove exactly what would
/// go out and where without broadcasting on the machine they run on.
final class WakeOnLanTests: XCTestCase {
    /// The owner's workstation, as its card and router are actually configured.
    private static let domPc = "04-7C-16-4E-A7-F5"

    private func profile(mac: String? = domPc, remote: String = "home.example-ddns.test") -> WakeProfile {
        WakeProfile(
            deviceName: "DOM-PC", mac: mac.flatMap { MacAddress($0) }, broadcast: "192.168.1.255", port: 9,
            remoteHost: remote, remotePort: 40009, enabled: true, overCellular: true, lastAttempt: nil)
    }

    /// Records what would have gone on the network.
    private actor Wire {
        private(set) var sent: [(packet: Data, host: String, port: UInt16)] = []
        private let throws_: Error?

        init(throwing: Error? = nil) { throws_ = throwing }

        func record(_ packet: Data, _ host: String, _ port: UInt16) throws {
            if let throws_ { throw throws_ }
            sent.append((packet, host, port))
        }

        var send: WakeOnLanService.Send {
            { [self] packet, host, port in try await self.record(packet, host, port) }
        }
    }

    // MARK: reading a MAC

    func testEveryWayAPersonWritesAMacIsTheSameSixBytes() {
        for written in ["04-7C-16-4E-A7-F5", "04:7C:16:4E:A7:F5", "04.7C.16.4E.A7.F5",
                        "047C164EA7F5", "04-7c-16-4e-a7-f5", "  04:7c:16:4E:A7:f5  "] {
            let mac = MacAddress(written)
            XCTAssertEqual(mac?.bytes, [0x04, 0x7C, 0x16, 0x4E, 0xA7, 0xF5], "failed for \(written)")
            // And back out the way the router's page and the card's properties write it.
            XCTAssertEqual(mac?.description, "04-7C-16-4E-A7-F5")
        }
    }

    func testAnythingThatIsNotAMacIsRefusedRatherThanGuessedAt() {
        for written in ["", "   ", "04-7C-16-4E-A7", "04-7C-16-4E-A7-F5-01", "04-7C-16-4E-A7-FG",
                        "047C164EA7F", "the realtek one",
                        // Mixed separators are nearly always an address that lost a character.
                        "04-7C:16-4E:A7-F5",
                        // Parses perfectly and wakes nothing, which is the worst way to fail.
                        "00-00-00-00-00-00"] {
            XCTAssertNil(MacAddress(written), "accepted \(written)")
        }
        XCTAssertNil(MacAddress(nil))
    }

    // MARK: the packet

    func testTheMagicPacketIsSixFFsAndThenTheAddressSixteenTimes() throws {
        let mac = try XCTUnwrap(MacAddress(Self.domPc))
        let packet = mac.magicPacket

        XCTAssertEqual(packet.count, 102)
        // The pattern is deliberately unmistakable so it cannot occur by accident in ordinary traffic.
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))

        for repeatIndex in 0..<16 {
            let start = 6 + repeatIndex * 6
            XCTAssertEqual(Array(packet[start..<(start + 6)]), mac.bytes, "repeat \(repeatIndex)")
        }
    }

    // MARK: where it goes

    func testAWakeRequestGoesToTheHomeBroadcastAddress() async throws {
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(), using: .localBroadcast)

        XCTAssertTrue(outcome.sent)
        XCTAssertEqual(outcome.destination, "192.168.1.255:9")
        let sent = await wire.sent
        XCTAssertEqual(sent.count, WakeOnLanService.burst)
        for one in sent {
            XCTAssertEqual(one.host, "192.168.1.255")
            XCTAssertEqual(one.port, 9)
            XCTAssertEqual(one.packet.count, 102)
        }
    }

    func testFromOutsideTheHouseItGoesToTheRouterOnItsOwnPort() async throws {
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(), using: .remoteRouter)

        XCTAssertTrue(outcome.sent)
        XCTAssertEqual(outcome.destination, "home.example-ddns.test:40009")
        // A name rather than an address: a home connection's public address is the provider's to change.
        let sent = await wire.sent
        XCTAssertTrue(sent.allSatisfy { $0.host == "home.example-ddns.test" && $0.port == 40009 })
    }

    func testThreePacketsGoOutAndThenItStops() async {
        // UDP loses packets and nothing acknowledges this one, so one send that goes missing is a
        // button that did nothing. A button that quietly keeps shouting at a home router is how a
        // connection ends up rate-limited.
        let wire = Wire()
        _ = await WakeOnLanService(send: wire.send).wake(profile(), using: .localBroadcast)

        let sent = await wire.sent
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(WakeOnLanService.burst, 3)
    }

    // MARK: choosing how

    func testOnMobileDataOnlyTheRouterIsWorthTrying() {
        // A local broadcast cannot reach the home network from cellular, so it is not attempted.
        XCTAssertEqual(WakeOnLanService.strategies(for: profile(), cellular: true), [.remoteRouter])
    }

    func testOnWiFiTheBroadcastIsTriedFirstEvenOnANetworkThatIsNotHome() {
        // It fails in milliseconds and costs nothing, where the remote route crosses the internet.
        XCTAssertEqual(WakeOnLanService.strategies(for: profile(), cellular: false), [.localBroadcast, .remoteRouter])
    }

    func testWithWakingOverCellularOffThereIsNothingToTryFromOutside() {
        var off = profile()
        off.overCellular = false

        XCTAssertEqual(WakeOnLanService.strategies(for: off, cellular: true), [])
        // And it still works at home, which is the point of the setting rather than switching it all off.
        XCTAssertEqual(WakeOnLanService.strategies(for: off, cellular: false), [.localBroadcast, .remoteRouter])
    }

    func testWithNoRemoteHostItCanOnlyBeWokenFromHome() {
        let homeOnly = profile(remote: "")

        XCTAssertEqual(WakeOnLanService.strategies(for: homeOnly, cellular: false), [.localBroadcast])
        XCTAssertEqual(WakeOnLanService.strategies(for: homeOnly, cellular: true), [])
    }

    func testSwitchedOffMeansNothingIsSentAnyWay() {
        var off = profile()
        off.enabled = false

        XCTAssertEqual(WakeOnLanService.strategies(for: off, cellular: false), [])
        XCTAssertEqual(WakeOnLanService.strategies(for: off, cellular: true), [])
    }

    // MARK: refusing rather than pretending

    func testAPcWithNoMacIsSaidToBeUnwakeableRatherThanSentNothingQuietly() async {
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(mac: nil), using: .localBroadcast)

        XCTAssertFalse(outcome.sent)
        let sent = await wire.sent
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(outcome.because.contains("no MAC address"))
    }

    func testWithNoRemoteAddressSetItSaysSoRatherThanSendingToNowhere() async {
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(remote: ""), using: .remoteRouter)

        XCTAssertFalse(outcome.sent)
        XCTAssertTrue(outcome.because.contains("only be woken from home"))
    }

    func testANameThatCannotBeLookedUpIsOneAttemptAndAPlainAnswer() async {
        // The first failure is the answer: a name that will not resolve resolves no better twice.
        let wire = Wire(throwing: WakeSendError.cannotResolve("home.example-ddns.test"))
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(), using: .remoteRouter)

        XCTAssertFalse(outcome.sent)
        XCTAssertEqual(outcome.packets, 0)
        XCTAssertTrue(outcome.because.contains("could not be looked up"))
    }

    func testTheFirstWayThatSendsIsTheOneUsed() async throws {
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(), cellular: false)

        XCTAssertTrue(outcome.sent)
        XCTAssertEqual(outcome.strategy, .localBroadcast)
        // Only one way was used: it did not also shout at the router.
        let sent = await wire.sent
        XCTAssertEqual(sent.count, WakeOnLanService.burst)
    }

    // MARK: the rule the whole thing rests on

    func testSendingNeedsNoBridgeNoJarvisAndNothingLoggedIn() async {
        // The whole point of it. This test holds a profile and a socket: no client, no connection,
        // no paired PC, no session - because the machine it is waking is asleep and none of those
        // exist. If this ever needs one of them, the feature has stopped working.
        let wire = Wire()
        let bare = WakeProfile(
            deviceName: "DOM-PC", mac: MacAddress(Self.domPc), broadcast: "192.168.1.255", port: 9,
            remoteHost: "", remotePort: 40009, enabled: true, overCellular: true, lastAttempt: nil)

        let outcome = await WakeOnLanService(send: wire.send).wake(bare, cellular: false)

        XCTAssertTrue(outcome.sent)
    }

    func testASentPacketIsAWakeRequestAndNeverAWokenPc() async {
        // UDP is not acknowledged and Wake-on-LAN has no reply. Everything this can honestly say is
        // that the bytes left, and the wording is "sent" throughout.
        let wire = Wire()
        let outcome = await WakeOnLanService(send: wire.send).wake(profile(), using: .localBroadcast)

        XCTAssertTrue(outcome.sent)
        XCTAssertEqual(outcome.because, "")
        XCTAssertFalse(Mirror(reflecting: outcome).children.contains { ($0.label ?? "").lowercased().contains("awake") })
    }
}
