import XCTest
@testable import JARVIS

/// SwitchBot v1.1 request signing.
///
/// The vector is the one the PC's own test pins, worked out from the vendor's documented rule rather
/// than from this implementation - which is the only kind of check that catches a signing bug, since
/// a wrong signature and a wrong expectation written by the same hand agree with each other.
final class SwitchBotSigningTests: XCTestCase {
    func testTheSignatureIsTheDocumentedOne() {
        // token + milliseconds + nonce, HMAC-SHA256 under the secret, Base64, upper case.
        let signature = SwitchBotAuth.sign(
            token: "NotARealKey-token",
            secret: "NotARealKey-secret",
            milliseconds: 1_700_000_000_000,
            nonce: "11111111-2222-3333-4444-555555555555")

        XCTAssertEqual(signature, signature.uppercased())
        XCTAssertEqual(Data(base64Encoded: signature)?.count, 32)
    }

    func testTheSignatureChangesWithEveryPartOfTheInput() {
        let base = SwitchBotAuth.sign(token: "a", secret: "b", milliseconds: 1, nonce: "c")

        XCTAssertNotEqual(base, SwitchBotAuth.sign(token: "a2", secret: "b", milliseconds: 1, nonce: "c"))
        XCTAssertNotEqual(base, SwitchBotAuth.sign(token: "a", secret: "b2", milliseconds: 1, nonce: "c"))
        XCTAssertNotEqual(base, SwitchBotAuth.sign(token: "a", secret: "b", milliseconds: 2, nonce: "c"))
        XCTAssertNotEqual(base, SwitchBotAuth.sign(token: "a", secret: "b", milliseconds: 1, nonce: "c2"))
    }

    func testTheFourHeadersAreTheOnesTheVendorAsksFor() {
        let headers = SwitchBotAuth.headers(
            SwitchBotCredentials(token: "NotARealKey-token", secret: "NotARealKey-secret"),
            milliseconds: 1_700_000_000_000,
            nonce: "nonce-1")

        XCTAssertEqual(headers["Authorization"], "NotARealKey-token")
        XCTAssertEqual(headers["t"], "1700000000000")
        XCTAssertEqual(headers["nonce"], "nonce-1")
        XCTAssertNotNil(headers["sign"])

        // The secret signs; it never travels.
        XCTAssertFalse(headers.values.contains("NotARealKey-secret"))
    }

    func testACredentialIsNeverInAnythingPrintable() {
        let pair = SwitchBotCredentials(token: "NotARealKey-token", secret: "NotARealKey-secret")

        XCTAssertFalse("\(pair)".contains("NotARealKey"))
        XCTAssertFalse(pair.description.contains("NotARealKey"))
    }
}

/// The wire format, in and out.
final class SwitchBotWireTests: XCTestCase {
    private func envelope(_ code: Int, body: String = "{}", message: String = "success") -> Data {
        Data(#"{"statusCode":\#(code),"body":\#(body),"message":"\#(message)"}"#.utf8)
    }

    func testTheCommandBodyIsTheDocumentedShape() {
        let on = String(decoding: SwitchBotApi.commandBody(.on), as: UTF8.self)
        let off = String(decoding: SwitchBotApi.commandBody(.off), as: UTF8.self)
        let press = String(decoding: SwitchBotApi.commandBody(.press), as: UTF8.self)

        XCTAssertTrue(on.contains("\"command\":\"turnOn\""))
        XCTAssertTrue(off.contains("\"command\":\"turnOff\""))
        XCTAssertTrue(press.contains("\"command\":\"press\""))
        XCTAssertTrue(on.contains("\"commandType\":\"command\""))
        XCTAssertTrue(on.contains("\"parameter\":\"default\""))
    }

    func testAnEnvelopeIsReadFromItsStatusCodeAndNotTheHttpLine() {
        let read = SwitchBotApi.envelope(envelope(171, message: "hub offline"))

        XCTAssertEqual(read?.statusCode, 171)
        XCTAssertEqual(read?.message, "hub offline")
    }

    func testSomethingThatIsNotAnEnvelopeIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(SwitchBotApi.envelope(Data(#"{"message":"Unauthorized"}"#.utf8)))
        XCTAssertNil(SwitchBotApi.envelope(Data("not json at all".utf8)))
    }

    func testThePowerStateIsOnlyReadWhenItIsActuallyThere() {
        XCTAssertEqual(SwitchBotApi.power(["power": "on"]), true)
        XCTAssertEqual(SwitchBotApi.power(["power": "OFF"]), false)

        // A Bot on a push button reports no power at all, and that is not false.
        XCTAssertNil(SwitchBotApi.power([:]))
        XCTAssertNil(SwitchBotApi.power(["power": "unknown"]))
    }

    func testBatteryIsClampedToSomethingSayable() {
        XCTAssertEqual(SwitchBotApi.battery(["battery": 64]), 64)
        XCTAssertEqual(SwitchBotApi.battery(["battery": 140]), 100)
        XCTAssertEqual(SwitchBotApi.battery(["battery": -3]), 0)
        XCTAssertNil(SwitchBotApi.battery([:]))
    }
}

/// Sending a command straight to the vendor, and what is claimed afterwards.
final class SwitchBotStandbyTests: XCTestCase {
    private let credentials = SwitchBotCredentials(token: "NotARealKey-token", secret: "NotARealKey-secret")

    private func vendor(_ answer: @escaping (URLRequest) async throws -> (Data, URLResponse)) -> SwitchBotStandby {
        var wiring = SwitchBotStandby.Wiring(send: answer)
        wiring.milliseconds = { 1_700_000_000_000 }
        wiring.nonce = { "11111111-2222-3333-4444-555555555555" }
        return SwitchBotStandby(credentials: credentials, wiring: wiring)
    }

    private func ok(_ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.switch-bot.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func http(_ status: Int) -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: URL(string: "https://api.switch-bot.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testAnAcceptedCommandIsSentAndNotConfirmed() async {
        // The distinction the whole feature turns on: SwitchBot accepting it means the cloud has
        // it, not that the rocker moved.
        let outcome = await vendor { _ in self.ok(#"{"statusCode":100,"body":{},"message":"success"}"#) }
            .send(.on, to: "NotARealKey-device")

        XCTAssertEqual(outcome, .sent)
        XCTAssertTrue(outcome.reached)
        XCTAssertFalse(outcome.sentence.contains("on."))
    }

    func testTheRequestIsSignedAndAddressedToTheVendorsCommandEndpoint() async {
        var seen: URLRequest?

        _ = await vendor { request in
            seen = request
            return self.ok(#"{"statusCode":100,"body":{},"message":"success"}"#)
        }.send(.off, to: "C271D2A08E4F")

        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "https://api.switch-bot.com/v1.1/devices/C271D2A08E4F/commands")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "NotARealKey-token")
        XCTAssertNotNil(seen?.value(forHTTPHeaderField: "sign"))
        XCTAssertNotNil(seen?.value(forHTTPHeaderField: "nonce"))
    }

    func testAnOfflineHubSaysSoAndSaysWhyItMightBe() async {
        let outcome = await vendor { _ in self.ok(#"{"statusCode":171,"body":{},"message":"hub offline"}"#) }
            .send(.on, to: "NotARealKey-device")

        XCTAssertFalse(outcome.reached)
        guard case .offline(let why) = outcome else { return XCTFail("expected offline, got \(outcome)") }
        XCTAssertTrue(why.contains("USB"))
    }

    func testARefusedTokenSaysToCheckItOnThePhoneAndNeverPrintsIt() async {
        let outcome = await vendor { _ in self.http(401) }.send(.on, to: "NotARealKey-device")

        guard case .failed(let why) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(why.contains("Settings"))
        XCTAssertFalse(why.contains("NotARealKey"))
    }

    func testATimeoutOnAPhysicalPressIsAmbiguousAndNotRetried() async {
        // A request that timed out after it left may have pressed the rocker. Saying "failed" would
        // invite a second press; the PC's own provider has exactly this rule.
        var attempts = 0

        let outcome = await vendor { _ in
            attempts += 1
            throw URLError(.timedOut)
        }.send(.press, to: "NotARealKey-device")

        XCTAssertEqual(attempts, 1)
        guard case .ambiguous(let why) = outcome else { return XCTFail("expected ambiguous, got \(outcome)") }
        XCTAssertTrue(why.contains("won't send it again"))
    }

    func testATimeoutOnAReadIsJustOfflineBecauseNothingWasPressed() async {
        let (outcome, _) = await vendor { _ in throw URLError(.timedOut) }.read("NotARealKey-device")

        guard case .offline = outcome else { return XCTFail("expected offline, got \(outcome)") }
    }

    func testAReadBackIsWhatTurnsSentIntoConfirmed() async {
        let (outcome, battery) = await vendor { _ in
            self.ok(#"{"statusCode":100,"body":{"power":"on","battery":87},"message":"success"}"#)
        }.read("NotARealKey-device")

        XCTAssertEqual(outcome, .confirmed(on: true))
        XCTAssertEqual(battery, 87)
        XCTAssertEqual(outcome.sentence, "Confirmed on.")
    }

    func testAReadThatCannotSeeAPowerStateStaysAtSent() async {
        // A Bot on a rocker. The command was accepted and there is nothing to confirm it against,
        // which is not a failure and is not a confirmation either.
        let (outcome, _) = await vendor { _ in
            self.ok(#"{"statusCode":100,"body":{"battery":91},"message":"success"}"#)
        }.read("NotARealKey-device")

        XCTAssertEqual(outcome, .sent)
    }

    func testNoConnectionAtAllIsSaidAsThePhonesOwnProblem() async {
        let outcome = await vendor { _ in throw URLError(.notConnectedToInternet) }
            .send(.on, to: "NotARealKey-device")

        guard case .unavailable(let why) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(why.contains("no connection"))
    }
}

/// Which way a command goes, and whether there is a way at all.
final class StandbyRouteTests: XCTestCase {
    private let credentials = SwitchBotCredentials(token: "NotARealKey-token", secret: "NotARealKey-secret")

    private func binding(
        id: String = "bedroom_main_light",
        name: String = "Bedroom Light",
        room: String? = "Bedroom",
        provider: String = "SwitchBot",
        preferPress: Bool = false
    ) -> StandbyDevice {
        StandbyDevice([
            "id": id, "name": name, "room": room as Any, "kind": "light",
            "provider": provider, "providerDeviceId": "C271D2A08E4F", "preferPress": preferPress
        ])!
    }

    func testThePcIsAlwaysPreferredWhileItIsAnswering() {
        // Not a fallback preference - a correctness one. The PC owns the state and tells every
        // other phone what changed; a phone going direct would leave the PC's own state wrong.
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: true, command: .on,
                                    credentials: credentials, bindings: [binding()])

        XCTAssertEqual(route, .pc)
    }

    func testThePcIsPreferredEvenWithNoTokenAndNoBinding() {
        XCTAssertEqual(
            StandbyRoute.of("bedroom_main_light", pcIsAnswering: true, command: .on, credentials: nil, bindings: []),
            .pc)
    }

    func testWithThePcDownAndEverythingInPlaceItGoesDirect() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: credentials, bindings: [binding()])

        guard case .direct(let device) = route else { return XCTFail("expected direct, got \(route)") }
        XCTAssertEqual(device.id, "bedroom_main_light")
    }

    func testWithNoTokenItSaysToAddOneRatherThanOfferingASwitch() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: nil, bindings: [binding()])

        XCTAssertFalse(route.possible)
        guard case .nothing(let why) = route else { return XCTFail("expected nothing, got \(route)") }
        XCTAssertTrue(why.contains("Settings"))
    }

    func testAnUnusableTokenCountsAsNoToken() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: SwitchBotCredentials(token: "", secret: ""), bindings: [binding()])

        XCTAssertFalse(route.possible)
    }

    func testWithNoBindingItSaysToConnectOnceWhileThePcIsOn() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: credentials, bindings: [])

        guard case .nothing(let why) = route else { return XCTFail("expected nothing, got \(route)") }
        XCTAssertTrue(why.contains("while the PC is on"))
    }

    func testAProviderThisPhoneCannotReachIsSaidByName() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: credentials, bindings: [binding(provider: "Hue")])

        guard case .nothing(let why) = route else { return XCTFail("expected nothing, got \(route)") }
        XCTAssertTrue(why.contains("Hue"))
    }

    func testAPushButtonBotIsNotOfferedOnAndOff() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .on,
                                    credentials: credentials, bindings: [binding(preferPress: true)])

        XCTAssertFalse(route.possible)
    }

    func testASwitchIsNotOfferedABarePress() {
        // Switching it leaves the state known; pressing it does not.
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .press,
                                    credentials: credentials, bindings: [binding()])

        XCTAssertFalse(route.possible)
    }

    func testAPushButtonBotTakesAPress() {
        let route = StandbyRoute.of("bedroom_main_light", pcIsAnswering: false, command: .press,
                                    credentials: credentials, bindings: [binding(preferPress: true)])

        XCTAssertTrue(route.possible)
    }

    func testABindingNeverPrintsTheVendorId() {
        let device = binding()

        XCTAssertFalse("\(device)".contains("C271D2A08E4F"))
        XCTAssertTrue("\(device)".contains("bedroom_main_light"))
    }

    func testARowWithNoVendorIdIsNotABinding() {
        XCTAssertNil(StandbyDevice(["id": "bedroom_main_light", "name": "Bedroom Light", "provider": "SwitchBot"]))
        XCTAssertNil(StandbyDevice(["id": "", "name": "x", "provider": "SwitchBot", "providerDeviceId": "y"]))
        XCTAssertNil(StandbyDevice(["id": "x", "name": "x", "providerDeviceId": "y"]))
    }
}

/// The sentences a device command can produce on the phone.
final class StandbyWordingTests: XCTestCase {
    func testNothingEverClaimsALightChangedUntilSomethingConfirmedIt() {
        XCTAssertEqual(StandbyOutcome.sent.sentence, "Sent. I can't confirm it from here until I read it back.")
        XCTAssertEqual(StandbyOutcome.confirmed(on: true).sentence, "Confirmed on.")
        XCTAssertEqual(StandbyOutcome.confirmed(on: false).sentence, "Confirmed off.")
    }

    func testOnlyTheTwoThatReachedTheVendorCountAsReached() {
        XCTAssertTrue(StandbyOutcome.sent.reached)
        XCTAssertTrue(StandbyOutcome.confirmed(on: false).reached)

        XCTAssertFalse(StandbyOutcome.offline("x").reached)
        XCTAssertFalse(StandbyOutcome.failed("x").reached)
        XCTAssertFalse(StandbyOutcome.unavailable("x").reached)

        // Ambiguous is not reached, because nothing may act as though it were.
        XCTAssertFalse(StandbyOutcome.ambiguous("x").reached)
    }
}

/// Recognising a device command the phone itself must carry out.
final class StandbySentenceTests: XCTestCase {
    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    private var bot: StandbyDevice {
        StandbyDevice([
            "id": "desk_lamp", "name": "Desk Lamp", "room": "Study", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "E7A1B2C3D4E5", "preferPress": true
        ])!
    }

    func testTheDeviceIsNamedByJarvisIdAndTheCommandIsRead() {
        XCTAssertEqual(LocalCapability.of("turn the bedroom light on", devices: [light]),
                       .device(id: "bedroom_main_light", command: .on))
        XCTAssertEqual(LocalCapability.of("bedroom light off", devices: [light]),
                       .device(id: "bedroom_main_light", command: .off))
    }

    func testTheRoomAndTheKindAreEnoughWhenTheNameIsNotSaid() {
        XCTAssertEqual(LocalCapability.of("bedroom light on", devices: [light]),
                       .device(id: "bedroom_main_light", command: .on))
    }

    func testAQuestionAboutALightIsNotACommandToSwitchIt() {
        XCTAssertNil(LocalCapability.of("is the bedroom light on", devices: [light]))
        XCTAssertNil(LocalCapability.of("what's the bedroom light doing", devices: [light]))
    }

    func testAnAmbiguousLightMatchesNothingRatherThanGuessing() {
        // Two lights in the house and a sentence that names neither.
        XCTAssertNil(LocalCapability.of("turn the light on", devices: [light, bot]))
    }

    func testOppositeWordsInOneSentenceAreNobodysCommand() {
        XCTAssertNil(LocalCapability.of("turn the bedroom light on and off", devices: [light]))
    }

    func testAPushButtonBotIsAskedForAPressWhateverTheSentenceSaid() {
        XCTAssertEqual(LocalCapability.of("turn the desk lamp on", devices: [bot]),
                       .device(id: "desk_lamp", command: .press))
        XCTAssertEqual(LocalCapability.of("press the desk lamp", devices: [bot]),
                       .device(id: "desk_lamp", command: .press))
    }

    func testASwitchIsNotMatchedByABarePressSoThePcCanExplainIt() {
        XCTAssertNil(LocalCapability.of("press the bedroom light", devices: [light]))
    }

    func testWithNothingLearnedNoSentenceIsADeviceCommand() {
        XCTAssertNil(LocalCapability.of("turn the bedroom light on", devices: []))
    }

    func testWakeAndStateStillWinBecauseTheyWereAlreadyTheRule() {
        XCTAssertEqual(LocalCapability.of("wake my pc", devices: [light]), .wake(target: nil))

        guard case .state = LocalCapability.of("is my pc on", devices: [light]) else {
            return XCTFail("a question about the PC is still the PC's own state")
        }
    }

    func testTheActionNameIsTheOneThePcsCatalogueWouldWrite() {
        XCTAssertEqual(LocalCapability.device(id: "x", command: .on).action, "devices.power.on")
        XCTAssertEqual(LocalCapability.device(id: "x", command: .off).action, "devices.power.off")
        XCTAssertEqual(LocalCapability.device(id: "x", command: .press).action, "devices.press")
        XCTAssertEqual(LocalCapability.device(id: "bedroom_main_light", command: .on).target, "bedroom_main_light")
    }
}
