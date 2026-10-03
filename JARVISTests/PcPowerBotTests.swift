import XCTest
@testable import JARVIS

/// The Bot on the PC's power button: the signature, and the order it is tried in.
///
/// This is the one place the phone holds a vendor credential, so the parts that can be checked
/// without a network are checked here rather than discovered on a night the PC will not come on.
final class PcPowerBotTests: XCTestCase {
    private static func profile(remote: String, overCellular: Bool) -> WakeProfile {
        WakeProfile(
            deviceName: "DOM-PC", mac: MacAddress("04:7C:16:4E:A7:F5"), broadcast: "192.168.1.255", port: 9,
            remoteHost: remote, remotePort: 40009, enabled: true, overCellular: overCellular, lastAttempt: nil)
    }

    func testTheSignatureMatchesTheDocumentedRecipe() {
        // The same vector the PC's SwitchBotAuth is held to, computed with Python's hmac and
        // base64 modules rather than with either implementation. Two signers that agree only with
        // themselves are two bugs waiting to meet; this value was produced by neither of them.
        let sign = PcPowerBot.sign(
            token: "NotARealKey-token",
            secret: "NotARealKey-secret",
            milliseconds: 1_700_000_000_000,
            nonce: "11111111-2222-3333-4444-555555555555")

        XCTAssertEqual(sign, "N+CPKZ9ZMHALBNXLA2AYU01QRDGRCR/RUECNTGXECPM=")
    }

    func testTheSignatureIsCaseAndOrderSensitive() {
        // Guards the two mistakes that produce a signature which looks right: lower-cased Base64,
        // and the three parts concatenated in the wrong order.
        let right = PcPowerBot.sign(token: "a", secret: "b", milliseconds: 1, nonce: "c")

        XCTAssertEqual(right, right.uppercased())
        XCTAssertNotEqual(right, PcPowerBot.sign(token: "c", secret: "b", milliseconds: 1, nonce: "a"))
        XCTAssertNotEqual(right, PcPowerBot.sign(token: "a", secret: "c", milliseconds: 1, nonce: "b"))
    }

    func testThePowerButtonIsTheLastThingTried() {
        // A packet that wakes a machine which was only asleep is cheaper, quicker and gentler than
        // pressing its power button, so it is tried first wherever it can work. The button is the
        // one that works from anywhere, so it is never left out.
        let profile = Self.profile(remote: "home.example-ddns.test", overCellular: true)

        let atHome = WakeOnLanService.strategies(for: profile, cellular: false, powerButton: true)
        XCTAssertEqual(atHome.last, .powerButton)
        XCTAssertEqual(atHome.first, .localBroadcast)
    }

    func testOnMobileDataTheButtonIsStillOffered() {
        // The case the whole thing exists for. A broadcast cannot leave a phone on mobile data, so
        // without the button a PC that is off and a user who is out is simply the end of it.
        // No way in from outside: no remote host, and not allowed over cellular anyway.
        let profile = Self.profile(remote: "", overCellular: false)

        let out = WakeOnLanService.strategies(for: profile, cellular: true, powerButton: true)

        XCTAssertEqual(out, [.powerButton])
    }

    func testWithoutTheButtonNothingChanges() {
        // A phone that has never been handed the button behaves exactly as before.
        let profile = Self.profile(remote: "", overCellular: false)

        XCTAssertTrue(WakeOnLanService.strategies(for: profile, cellular: true, powerButton: false).isEmpty)
    }

    func testEveryStatusCodeSaysWhatToDoAboutIt() {
        // Never a bare number: 161 is a flat battery or a Bot out of Bluetooth range, and 171 is
        // the hub, and somebody standing in their hallway needs to know which.
        XCTAssertTrue(PcPowerBot.wording(161, "the power button").contains("offline"))
        XCTAssertTrue(PcPowerBot.wording(171, "the power button").contains("hub"))
        XCTAssertTrue(PcPowerBot.wording(401, "the power button").contains("no longer valid"))
        XCTAssertTrue(PcPowerBot.wording(12345, "the power button").contains("12345"))
    }

    func testTheHandoverRoundTripsThroughTheKeychain() throws {
        // The Simulator has a Keychain, so this is a real store and a real read.
        PcPowerBot.forget()
        XCTAssertFalse(PcPowerBot.isSetUp)

        let handed = PcPowerBot.Handover(
            token: "NotARealKey-token",
            secret: "NotARealKey-secret",
            deviceId: "EC6F03866A46",
            name: "PC power",
            preferPress: true)

        try PcPowerBot.remember(handed)

        XCTAssertTrue(PcPowerBot.isSetUp)
        XCTAssertEqual(PcPowerBot.buttonName, "PC power")
        XCTAssertEqual(PcPowerBot.stored(), handed)

        PcPowerBot.forget()
        XCTAssertFalse(PcPowerBot.isSetUp)
        XCTAssertNil(PcPowerBot.stored())
    }
}
