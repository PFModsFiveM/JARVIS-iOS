import XCTest
@testable import JARVIS

/// The things in the house, and which buttons each of them gets.
///
/// The PC is two devices in one and that is what these hold to: wake-on-LAN is a packet to a
/// network card and works while the machine is off, and everything else is a request to JARVIS and
/// needs it awake. A panel that offered "sleep" for a machine JARVIS is not running on, or hid
/// "turn on" because the PC was not answering, would be a panel that lies about what it can do.
final class HomeControlTests: XCTestCase {
    private func pc(awake: Bool = true, wakeable: Bool = true) -> ControlledDevice {
        ControlledDevice(id: "pc", name: "DOM-PC", kind: .pc, detail: "", awake: awake, wakeable: wakeable)
    }

    private func machine(_ name: String = "the server") -> ControlledDevice {
        ControlledDevice(id: "machine:\(name)", name: name, kind: .machine, detail: "", awake: false, wakeable: true)
    }

    // MARK: what each kind of thing can do

    func testThePcOffersEverythingIncludingTurningItOn() {
        let ids = HomeControlModel.actions(for: pc()).map(\.id)

        XCTAssertEqual(ids, ["wake", "lock", "sleep", "restart", "shutdown", "cancel"])
    }

    func testAnotherMachineOnlyOffersTurningItOn() {
        // JARVIS is not running on it. There is nobody there to be asked to sleep, and a button
        // that would always fail is worse than no button.
        XCTAssertEqual(HomeControlModel.actions(for: machine()).map(\.id), ["wake"])
    }

    func testTheOnesThatEndASessionAskFirst() {
        let actions = HomeControlModel.actions(for: pc())

        for action in actions where ["sleep", "restart", "shutdown"].contains(action.id) {
            XCTAssertNotNil(action.confirm, "\(action.id) should ask before it happens")
        }

        for action in actions where ["wake", "lock", "cancel"].contains(action.id) {
            XCTAssertNil(action.confirm, "\(action.id) is reversible or harmless; it should not nag")
        }
    }

    func testShuttingDownIsTheMostSeriousButtonOnTheScreen() {
        let actions = HomeControlModel.actions(for: pc())
        let shutdown = actions.first { $0.id == "shutdown" }
        let cancel = actions.first { $0.id == "cancel" }

        XCTAssertEqual(shutdown?.severity, .grave)
        XCTAssertEqual(cancel?.severity, .good)
    }

    // MARK: what the PC says is on the network

    func testMachinesAreReadFromWhatThePcSays() {
        let read = HomeControlModel.read([
            ["name": "the server", "address": "192.168.1.42", "wakeable": true, "learnt": "seen on the network"],
            ["name": "the laptop", "address": "192.168.1.9", "wakeable": true, "learnt": "you told me"]
        ])

        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.first?.name, "the server")
        XCTAssertEqual(read.first?.detail, "Last seen at 192.168.1.42")
        XCTAssertEqual(read.first?.kind, .machine)
    }

    func testSomethingWithNoNetworkCardIsNotListed() {
        // Its only button would be "turn on", and turning it on is exactly what cannot be done
        // without a card to address. A row whose single action fails is not a row.
        let read = HomeControlModel.read([
            ["name": "the printer", "address": "192.168.1.12", "wakeable": false],
            ["name": "the server", "address": "192.168.1.42", "wakeable": true]
        ])

        XCTAssertEqual(read.map(\.name), ["the server"])
    }

    func testAMachineWithNoNameIsNotListed() {
        let read = HomeControlModel.read([["name": "", "wakeable": true], ["wakeable": true]])

        XCTAssertTrue(read.isEmpty)
    }

    func testAMachineWithNoAddressStillGetsASecondLine() {
        let read = HomeControlModel.read([["name": "the server", "wakeable": true]])

        XCTAssertEqual(read.first?.detail, "On your network")
    }

    func testAnOlderPcAnsweringWithNothingIsNotACrash() {
        // The `machines` request is new. A PC that predates it answers "failed", and a PC that has
        // learnt nothing answers with an empty list; neither is a fault.
        XCTAssertTrue(HomeControlModel.read([]).isEmpty)
        XCTAssertTrue(HomeControlModel.read([["something": "unexpected"]]).isEmpty)
    }

    func testEveryDeviceHasItsOwnIdentity() {
        // They go into a ForEach. Two rows sharing an id is a SwiftUI list that reuses the wrong
        // one when it redraws, which here would mean tapping one machine and waking another.
        let devices = HomeControlModel.read([
            ["name": "the server", "wakeable": true],
            ["name": "the laptop", "wakeable": true]
        ])

        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertFalse(devices.contains { $0.id == "pc" }, "nothing from the network may collide with the PC's own row")
    }
}
