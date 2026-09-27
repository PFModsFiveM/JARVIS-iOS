import XCTest
@testable import JARVIS

/// Reading what the PC says about being woken: its own wake setup, and what its listener heard.
///
/// The bodies here are the shapes the PC's bridge sends (camel-cased JSON), so a rename on either
/// side shows up as a failing read rather than as an empty screen.
final class WakeDiagnosisTests: XCTestCase {
    func testAReadinessReplyIsReadCheckByCheck() throws {
        let body: [String: Any] = [
            "checks": [
                ["check": "nic", "state": "Ok", "title": "Network card", "detail": "Realtek PCIe GbE Family Controller"],
                ["check": "armed", "state": "Problem", "title": "Allowed to wake the PC", "detail": "Tick the box."],
                ["check": "cgnat", "state": "Unknown", "title": "Public address (CGNAT)", "detail": "Cannot be ruled out."]
            ],
            "cannotKnow": ["Whether the router forwards the wake port."]
        ]

        let report = try XCTUnwrap(WakeReadinessReport.read(body))

        XCTAssertEqual(report.checks.map(\.id), ["nic", "armed", "cgnat"])
        XCTAssertEqual(report.firstProblem?.id, "armed")
        XCTAssertEqual(report.checks[2].state, .unknown)
        XCTAssertEqual(report.cannotKnow.count, 1)
    }

    func testAStateThisAppDoesNotKnowIsReadAsUnknownNotAsAFault() throws {
        let body: [String: Any] = ["checks": [["check": "new", "state": "SomethingNew", "title": "New", "detail": ""]]]

        XCTAssertEqual(try XCTUnwrap(WakeReadinessReport.read(body)).checks.first?.state, .unknown)
    }

    func testSomethingThatIsNotAReadinessReplyIsNotRead() {
        XCTAssertNil(WakeReadinessReport.read(["message": "This PC can't diagnose waking."]))
    }

    func testAProbeReplyCarriesTheCountsAndThePcsOwnSentence() throws {
        let body: [String: Any] = [
            "state": "Finished", "port": 9, "forThisPc": 3, "forAnother": 0, "other": 1,
            "fromOutside": 3, "fromHome": 0,
            "meaning": "3 magic packets for this PC arrived from outside the house."
        ]

        let probe = try XCTUnwrap(WakeProbeReport.read(body))

        XCTAssertEqual(probe.state, .finished)
        XCTAssertEqual(probe.fromOutside, 3)
        XCTAssertFalse(probe.isListening)
        XCTAssertTrue(probe.meaning.contains("from outside"))
    }

    func testAListeningProbeIsListening() throws {
        let probe = try XCTUnwrap(WakeProbeReport.read(["state": "Listening", "port": 9, "meaning": ""]))

        XCTAssertTrue(probe.isListening)
        XCTAssertEqual(probe.forThisPc, 0)
    }
}
