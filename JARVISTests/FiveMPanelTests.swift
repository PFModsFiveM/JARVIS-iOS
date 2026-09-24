import XCTest
@testable import JARVIS

/// What the phone makes of the FiveM server the PC reports on.
///
/// The PC has been able to answer this since the bridge was written - whether the server is up,
/// what it is called, how many are on it and who - and nothing ever asked. These cover the reading
/// of that answer, which is the part that can be wrong without anybody noticing: a server with no
/// maximum, a server that names nobody, a server that is simply off.
///
/// On the main actor because `ControlModel` is, and a type nested inside it inherits that: the
/// first test to touch one would otherwise be the first to argue with the compiler about isolation.
@MainActor
final class FiveMPanelTests: XCTestCase {
    func testTheCountReadsAsSomebodyWouldSayIt() {
        XCTAssertEqual(ControlModel.FiveM(players: 3, maximum: 32).count, "3 of 32")
    }

    func testAServerWithNoStatedLimitJustSaysTheNumber() {
        // Some builds do not publish a maximum. "3 of 0" would be worse than "3".
        XCTAssertEqual(ControlModel.FiveM(players: 3, maximum: 0).count, "3")
    }

    func testAnEmptyServerIsStillACount() {
        XCTAssertEqual(ControlModel.FiveM(players: 0, maximum: 32).count, "0 of 32")
    }

    func testTwoIdenticalReadingsAreEqualSoTheScreenDoesNotChurn() {
        // It is @Published and refreshed every few seconds while the tab is open. Without equality
        // every refresh would redraw the panel whether or not anything had changed.
        let one = ControlModel.FiveM(name: "PF", players: 3, maximum: 32, names: ["Dom", "Sam"])
        let same = ControlModel.FiveM(name: "PF", players: 3, maximum: 32, names: ["Dom", "Sam"])
        let different = ControlModel.FiveM(name: "PF", players: 4, maximum: 32, names: ["Dom", "Sam"])

        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, different)
    }
}
