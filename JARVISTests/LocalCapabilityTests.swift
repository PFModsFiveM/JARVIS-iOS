import XCTest
@testable import JARVIS

/// The few requests this phone answers itself, and the many it must not.
///
/// The rule is narrow on purpose: only what is impossible while the PC is off. "Wake my PC" sent to
/// a sleeping PC is a request with nowhere to go; everything else belongs on the PC, where the
/// understanding is, rather than being reimplemented in the phone's own words.
final class LocalCapabilityTests: XCTestCase {
    func testEveryWayOfAskingForAWakeIsTheSameAction() {
        // Not five string comparisons in five places: one reading, used by the button, the typed
        // box, the wake word and Siri alike.
        for said in ["JARVIS, wake my PC.", "Turn my computer on", "Wake the workstation",
                     "Start my PC", "Get the workstation online", "wake up the pc",
                     "boot my machine", "switch the computer on", "power on my desktop",
                     "jarvis please wake the tower"] {
            guard case .wake = LocalCapability.of(said) else {
                return XCTFail("\(said) was not understood as a wake")
            }
            XCTAssertEqual(LocalCapability.of(said)?.action, "device.power.wake")
        }
    }

    func testTheOppositeRequestIsThePcsBusinessBecauseItIsAwakeToHearIt() {
        for said in ["turn the computer off", "shut the PC down", "put my computer to sleep",
                     "restart my PC", "reboot the workstation", "hibernate the machine"] {
            XCTAssertNil(LocalCapability.of(said), "\(said) was taken as a wake")
        }
    }

    func testAnythingThatIsNotAboutAMachineGoesToThePc() {
        // A phone that grabbed these would be worse than one that grabbed nothing.
        for said in ["wake me at seven", "turn the lights on", "start the render",
                     "what's playing", "power through this list", "boot up the game",
                     "turn the volume up", "switch to the other screen"] {
            XCTAssertNil(LocalCapability.of(said), "\(said) was taken as a wake")
        }
    }

    func testTurnTheComputerRoundIsNotAWakeRequest() {
        // "turn on" and "switch on" need the "on"; "wake" and "boot" do not.
        XCTAssertNil(LocalCapability.of("turn the computer round"))
        XCTAssertNotNil(LocalCapability.of("turn the computer on"))
    }

    func testANamedMachineIsCarriedThroughSoOneDayItCanBeOneOfSeveral() {
        XCTAssertEqual(LocalCapability.of("wake dom-pc")?.target, "dom")
        XCTAssertEqual(LocalCapability.of("wake the studio machine")?.target, "studio")
    }

    func testAnEmptySentenceIsNothing() {
        XCTAssertNil(LocalCapability.of(""))
        XCTAssertNil(LocalCapability.of("   "))
    }
}
