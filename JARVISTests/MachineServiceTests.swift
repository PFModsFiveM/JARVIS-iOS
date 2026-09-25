import Network
import XCTest
@testable import JARVIS

/// The PC's pre-login service, as this phone sees it.
///
/// The service exists to answer one question the desktop cannot: whether the machine is off, or on
/// with nobody signed in, or locked. So these hold to the two things that could quietly ruin that -
/// reading an answer wrongly, and dialling the wrong door with the right key.
final class MachineServiceTests: XCTestCase {
    private func pc(
        host: String? = "192.168.1.3",
        serviceName: String? = "JARVIS DOM-PC",
        remoteHosts: [String]? = ["100.101.102.103"],
        localHosts: [String]? = ["192.168.1.3"]
    ) -> PairedPC {
        PairedPC(deviceId: "device-1", serverKey: Data([1, 2, 3, 4]), serviceName: serviceName,
                 host: host, port: 47823, remoteHost: nil, remoteHosts: remoteHosts,
                 localHosts: localHosts, preferLocal: true)
    }

    private func status(
        machine: String = "DOM-PC",
        session: String = "Locked",
        described: String = "signed in, locked",
        desktop: String = "not running"
    ) -> [String: Any] {
        ["machine": machine, "service": "online", "session": session, "described": described,
         "desktop": desktop, "version": "1.0.0"]
    }

    // MARK: reading what it says

    func testItReadsTheMachinesState() {
        let report = MachineReport.read(status())

        XCTAssertEqual(report?.machine, "DOM-PC")
        XCTAssertEqual(report?.session, .locked)
        XCTAssertEqual(report?.described, "signed in, locked")
        XCTAssertEqual(report?.desktopRunning, false)
    }

    func testTheDesktopRunningIsSeparateFromTheMachineBeingOn() {
        // The distinction the whole endpoint exists for: reaching the service proves the machine is
        // on, and says nothing about whether JARVIS can be asked anything.
        XCTAssertEqual(MachineReport.read(status(desktop: "online"))?.desktopRunning, true)
        XCTAssertEqual(MachineReport.read(status(desktop: "not running"))?.desktopRunning, false)
    }

    func testAnAnswerItCannotReadIsNoAnswer() {
        // Not a machine in an unknown state - no report at all. A row that invented one would say
        // the PC was on because something replied.
        XCTAssertNil(MachineReport.read([:]))
        XCTAssertNil(MachineReport.read(status(machine: "")))
        XCTAssertNil(MachineReport.read(["machine": "DOM-PC"]))
        XCTAssertNil(MachineReport.read(status(session: "Sleeping")))
    }

    func testEverySessionTheServiceCanReportIsUnderstood() {
        // The four the service can send. A fifth appearing here means the two sides have drifted.
        for state in ["NobodySignedIn", "Locked", "InUse", "Unknown"] {
            XCTAssertNotNil(MachineReport.read(status(session: state)), "\(state) should be read")
        }
    }

    func testItSaysSomethingUsefulForEachState() {
        func summary(_ session: String, desktop: String = "not running") -> String? {
            MachineReport.read(status(session: session, desktop: desktop))?.summary
        }

        XCTAssertEqual(summary("NobodySignedIn"), "On, nobody signed in")
        XCTAssertEqual(summary("Locked"), "Locked, JARVIS not running")
        XCTAssertEqual(summary("Locked", desktop: "online"), "Locked")
        XCTAssertEqual(summary("InUse", desktop: "online"), "Awake")
    }

    // MARK: where it is looked for

    private func hosts(_ candidates: [BridgeCandidate]) -> [String] { candidates.map(\.describedAs) }

    func testTheServiceIsLookedForOnItsOwnPort() {
        let found = BridgeEndpointResolver.serviceCandidates(
            for: pc(), port: MachineService.defaultPort, cellular: false)

        XCTAssertFalse(found.isEmpty)

        for candidate in found {
            XCTAssertTrue(candidate.describedAs.hasSuffix(":47824"),
                          "\(candidate.describedAs) should be the service's port")
            XCTAssertFalse(candidate.describedAs.contains("47823"))
        }
    }

    func testBonjourIsNeverUsedForTheService() {
        // What the PC advertises is the desktop, on the desktop's port. A Bonjour candidate here
        // would dial desktop JARVIS and present the service's key to it - which is precisely the
        // confusion pinning exists to catch, arriving as "that PC is not the one this phone paired
        // with" on a PC that is perfectly fine.
        let found = BridgeEndpointResolver.serviceCandidates(
            for: pc(), port: MachineService.defaultPort, cellular: false)

        XCTAssertFalse(found.contains { $0.source == .discovered })
        XCTAssertFalse(hosts(found).contains { $0.contains("Bonjour") })
    }

    func testOnMobileDataOnlyTheAddressesThatCanWorkAreTried() {
        let found = BridgeEndpointResolver.serviceCandidates(
            for: pc(), port: MachineService.defaultPort, cellular: true)

        XCTAssertEqual(hosts(found), ["100.101.102.103:47824"])
    }

    func testAMachineWithNoAddressYetHasNowhereToTry() {
        // Nothing to dial is not the same as dialling and failing: the panel should say so rather
        // than report a connection that was never attempted.
        let unknown = PairedPC(deviceId: "device-1", serverKey: Data([1]), serviceName: "JARVIS DOM-PC",
                               host: nil, port: 47823, remoteHost: nil, remoteHosts: nil,
                               localHosts: nil, preferLocal: true)

        XCTAssertTrue(BridgeEndpointResolver.serviceCandidates(
            for: unknown, port: MachineService.defaultPort, cellular: false).isEmpty)
    }

    // MARK: the row it produces

    func testThePcRowSaysWhatTheMachineSaidWhenJarvisIsNotAnswering() {
        let report = MachineReport.read(status(session: "NobodySignedIn", described: "nobody has signed in"))!

        let row = HomeControlModel.pc(name: "DOM-PC", online: false, wakeable: true, machine: report)

        XCTAssertEqual(row.detail, "On, nobody signed in")
        XCTAssertFalse(row.awake)

        // On, but not answering: the state that used to be indistinguishable from "off", and the
        // one where pressing "turn on" would do nothing at all.
        XCTAssertTrue(row.powered)
    }

    func testWithNothingHeardTheRowStillSaysNotAnswering() {
        let row = HomeControlModel.pc(name: "DOM-PC", online: false, wakeable: true, machine: nil)

        XCTAssertEqual(row.detail, "Not answering")
        XCTAssertFalse(row.powered)
    }

    func testJarvisAnsweringOutranksAnythingTheServiceSaid() {
        // Both could be true at once, and the desktop is the better informed of the two.
        let stale = MachineReport.read(status(session: "Locked"))!

        let row = HomeControlModel.pc(name: "DOM-PC", online: true, wakeable: true, machine: stale)

        XCTAssertEqual(row.detail, "Awake")
        XCTAssertTrue(row.awake)
    }

    // MARK: the two pairings

    func testTheServiceIsASecondPairingOnItsOwnPort() {
        // Not the desktop's port, and not the desktop's key. Two processes cannot hold one port,
        // and a service running before sign-in cannot open a key sealed to the owner's account.
        XCTAssertNotEqual(MachineService.defaultPort, JarvisService.defaultPort)
        XCTAssertEqual(PairedService(deviceId: "d", serverKey: Data([9])).port, MachineService.defaultPort)
    }

    func testTheKeyIsShownAsAFingerprintRatherThanAKey() {
        let service = PairedService(deviceId: "d", serverKey: Data([1, 2, 3, 4, 5]))

        XCTAssertEqual(service.fingerprint.count, 8)
        XCTAssertFalse(service.fingerprint.contains("="))
    }
}
