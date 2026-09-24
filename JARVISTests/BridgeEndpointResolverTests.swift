import Network
import XCTest
@testable import JARVIS

/// Where the PC is looked for, and in what order.
///
/// This used to be two candidates and a coin toss - the home address and a typed away-from-home one,
/// ordered by whether the phone was on mobile data - which is wrong in both directions. On a café's
/// Wi-Fi the phone is not on cellular, so the home address went first and reached nothing. On mobile
/// data with nothing typed there was nothing to try at all.
final class BridgeEndpointResolverTests: XCTestCase {
    private func pc(
        host: String? = "192.168.1.3",
        serviceName: String? = "JARVIS DOM-PC",
        remoteHost: String? = nil,
        remoteHosts: [String]? = ["dom-pc.tailnet-name.ts.net", "100.101.102.103"],
        localHosts: [String]? = ["192.168.1.3"],
        preferLocal: Bool? = true
    ) -> PairedPC {
        PairedPC(deviceId: "device-1", serverKey: Data([1, 2, 3, 4]), serviceName: serviceName,
                 host: host, port: 47823, remoteHost: remoteHost, remoteHosts: remoteHosts,
                 localHosts: localHosts, preferLocal: preferLocal)
    }

    private func hosts(_ candidates: [BridgeCandidate]) -> [String] { candidates.map(\.describedAs) }

    private var bonjour: [FoundPC] {
        [FoundPC(name: "JARVIS DOM-PC",
                 endpoint: .service(name: "JARVIS DOM-PC", type: JarvisService.type, domain: JarvisService.domain, interface: nil))]
    }

    func testBonjourWinsOnTheNetworkWhereItCanSeeThePc() {
        // Seeing the PC here is proof the phone is at home rather than a guess about it, which is
        // why it outranks everything else.
        let found = BridgeEndpointResolver.candidates(for: pc(), discovered: bonjour, cellular: false)

        XCTAssertEqual(found.first?.source, .discovered)
        XCTAssertTrue(hosts(found).contains("JARVIS DOM-PC (found on this network)"))
    }

    func testOnMobileDataOnlyThePrivateNetworkIsTried() {
        // A home address cannot answer from cellular. Including it would spend the timeout on
        // something that cannot work - which is exactly what the old order did.
        let found = BridgeEndpointResolver.candidates(for: pc(), discovered: [], cellular: true)

        XCTAssertEqual(hosts(found), ["dom-pc.tailnet-name.ts.net:47823", "100.101.102.103:47823"])
        XCTAssertFalse(hosts(found).contains { $0.hasPrefix("192.168.") })
    }

    func testOnMobileDataWithNothingSetUpThereIsNothingToTryAndItSaysSo() {
        let found = BridgeEndpointResolver.candidates(
            for: pc(remoteHosts: nil), discovered: [], cellular: true)

        XCTAssertTrue(found.isEmpty)
    }

    func testOnAWiFiThatIsNotHomeThePrivateNetworkStillGetsATurn() {
        // A café's Wi-Fi: not cellular, and Bonjour finds nothing. The old order put the home
        // address first and stopped.
        let found = BridgeEndpointResolver.candidates(for: pc(), discovered: [], cellular: false)

        XCTAssertTrue(hosts(found).contains("dom-pc.tailnet-name.ts.net:47823"))
        XCTAssertTrue(hosts(found).contains("192.168.1.3:47823"))
    }

    func testPreferringLocalPutsTheHomeNetworkFirstWhenTheresProofItIsThere() {
        let found = BridgeEndpointResolver.candidates(for: pc(preferLocal: true), discovered: bonjour, cellular: false)
        let names = hosts(found)

        XCTAssertLessThan(names.firstIndex(of: "192.168.1.3:47823")!,
                          names.firstIndex(of: "dom-pc.tailnet-name.ts.net:47823")!)
    }

    func testTurningThatOffGoesRoundByThePrivateNetworkEvenAtHome() {
        // Somebody who wants one route everywhere can have it: the same path in and out of the house.
        let found = BridgeEndpointResolver.candidates(for: pc(preferLocal: false), discovered: [], cellular: false)
        let names = hosts(found)

        XCTAssertLessThan(names.firstIndex(of: "dom-pc.tailnet-name.ts.net:47823")!,
                          names.firstIndex(of: "192.168.1.3:47823")!)
    }

    func testWhatTheOwnerTypedComesBeforeWhatThePcSaid() {
        // Somebody who has gone to the trouble meant it.
        let found = BridgeEndpointResolver.candidates(
            for: pc(remoteHost: "typed.example.test"), discovered: [], cellular: true)

        XCTAssertEqual(found.first?.describedAs, "typed.example.test:47823")
    }

    func testTheNameIsAlwaysWorthKeepingAsALastResort() {
        // Bonjour resolves only on the PC's own network, but it is the one candidate that still
        // works when every address the PC has has changed.
        let found = BridgeEndpointResolver.candidates(for: pc(), discovered: [], cellular: false)

        XCTAssertEqual(found.last?.describedAs, "JARVIS DOM-PC (Bonjour)")
    }

    func testAnAddressIsNeverTriedTwice() {
        let found = BridgeEndpointResolver.candidates(
            for: pc(host: "192.168.1.3", localHosts: ["192.168.1.3", "192.168.1.3"]),
            discovered: [], cellular: false)

        XCTAssertEqual(Set(hosts(found)).count, found.count)
    }

    func testEveryCandidateGetsAShortTurnRatherThanAMinute() {
        // An address that cannot be reached from this network does not fail - the connection waits -
        // so the timeout is what moves on to the next one. It has to be short enough to walk the
        // whole list while somebody is looking at the screen.
        XCTAssertLessThanOrEqual(BridgeEndpointResolver.perCandidate, 5)
    }

    // MARK: mobile data

    func testMobileDataGetsLongerPerAddressThanWiFi() {
        // Two and a half seconds is right when the list is long and the network is a LAN. On mobile
        // data every local address has already been dropped, so the list is short and there is
        // nothing else to spend the time on - and the radio bringing a data context up and a tunnel
        // being established on demand are both slower than a handshake at home.
        XCTAssertGreaterThan(
            BridgeEndpointResolver.patience(cellular: true),
            BridgeEndpointResolver.patience(cellular: false))

        XCTAssertEqual(BridgeEndpointResolver.patience(cellular: false), BridgeEndpointResolver.perCandidate)
    }

    func testButNotSoLongThatSomebodyGivesUpFirst() {
        // Three private addresses at this much each is the worst case, and it has to stay inside
        // the patience of a person holding a phone.
        XCTAssertLessThanOrEqual(BridgeEndpointResolver.perCandidateOnCellular * 3, 30)
    }

    func testOnMobileDataAnAddressIsTriedBeforeAName() {
        // Each attempt now costs eight seconds, so the order matters in a way it did not. An
        // address needs nothing looked up; the name needs the tunnel's own resolver, which on
        // mobile data is one more thing that has to come up first.
        let candidates = BridgeEndpointResolver.candidates(
            for: pc(remoteHosts: ["dom-pc.tailnet-name.ts.net", "100.101.102.103", "fd7a:115c:a1e0::1"]),
            discovered: [],
            cellular: true)

        let first = candidates.first?.name ?? ""

        XCTAssertTrue(BridgeEndpointResolver.isLiteralAddress(first), "\(first) should not need DNS")
        XCTAssertTrue(hosts(candidates).contains { $0.contains("tailnet-name") }, "the name is still worth trying")
    }

    func testAndTheNameIsStillOfferedBecauseAddressesCanChange() {
        let candidates = BridgeEndpointResolver.candidates(
            for: pc(remoteHosts: ["dom-pc.tailnet-name.ts.net", "100.101.102.103"]),
            discovered: [],
            cellular: true)

        XCTAssertEqual(candidates.count, 2)
    }

    func testOnWiFiTheOrderThePcGaveIsKept() {
        // The reason for the reshuffle is mobile data's, and nothing else should feel it: at home
        // the name resolves instantly and is the one that survives an address changing.
        let candidates = BridgeEndpointResolver.candidates(
            for: pc(host: nil, remoteHosts: ["dom-pc.tailnet-name.ts.net", "100.101.102.103"], localHosts: nil),
            discovered: [],
            cellular: false,
            preferLocal: false)

        XCTAssertEqual(candidates.first?.name, "dom-pc.tailnet-name.ts.net")
    }

    func testWhatCountsAsAnAddressRatherThanAName() {
        XCTAssertTrue(BridgeEndpointResolver.isLiteralAddress("100.101.102.103"))
        XCTAssertTrue(BridgeEndpointResolver.isLiteralAddress("fd7a:115c:a1e0::cd01:e2ee"))
        XCTAssertFalse(BridgeEndpointResolver.isLiteralAddress("dom-pc.tailnet-name.ts.net"))
        XCTAssertFalse(BridgeEndpointResolver.isLiteralAddress(""))
    }

    func testTheSamePairingWorksOnEveryAddress() {
        // Identity is cryptographic, not where it answered: the PC proves it holds the key this
        // phone pinned, on whichever address. Nothing in a candidate carries a key, a device id or
        // anything else that could differ between routes.
        let candidates = BridgeEndpointResolver.candidates(for: pc(), discovered: bonjour, cellular: false)

        for candidate in candidates {
            XCTAssertFalse(candidate.describedAs.contains("device-1"))
            XCTAssertFalse(Mirror(reflecting: candidate).children.contains { ($0.label ?? "").lowercased().contains("key") })
        }
    }
}
