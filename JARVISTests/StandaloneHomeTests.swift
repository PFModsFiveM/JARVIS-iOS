import XCTest
@testable import JARVIS

/// Mobile JARVIS switching a light with PC-PRIME off.
///
/// The acceptance case for Phase 1, and the one the owner reported as unreliable. Each test here
/// corresponds to something that was actually broken rather than to a shape of the code.
final class StandaloneHomeTests: XCTestCase {
    private var light: StandbyDevice {
        StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Light", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!
    }

    private var lamp: StandbyDevice {
        StandbyDevice([
            "id": "desk_lamp", "name": "Desk Lamp", "room": "Study", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "E7A1B2C3D4E5", "preferPress": true
        ])!
    }

    private var kettle: StandbyDevice {
        StandbyDevice([
            "id": "kitchen_kettle", "name": "Kettle", "room": "Kitchen", "kind": "plug",
            "provider": "SwitchBot", "providerDeviceId": "AABBCCDDEEFF", "preferPress": false
        ])!
    }

    // MARK: How the owner actually says it

    /// With one light in the house, the shortest thing anybody says about a light should work.
    ///
    /// All of these failed before: the rule required every word of the device's name, so a house
    /// with one light still had to be told which one.
    func testOneLightAnswersToTheWordsPeopleUse() {
        let said = [
            "lights out": StandbyCommand.off,
            "lights on": .on,
            "turn the light off": .off,
            "turn my light off": .off,
            "put the light on": .on,
            "light on": .on
        ]

        for (sentence, expected) in said {
            XCTAssertEqual(LocalCapability.of(sentence, devices: [light]),
                           .device(id: "bedroom_main_light", command: expected),
                           "\(sentence) should have switched the one light")
        }
    }

    /// And must not, the moment there are two of them.
    func testTwoLightsRefuseTheShortFormRatherThanPickingOne() {
        for sentence in ["lights out", "turn the light off", "put the light on"] {
            XCTAssertNil(LocalCapability.of(sentence, devices: [light, lamp]),
                         "\(sentence) names neither of two lights and should go to the PC")
        }
    }

    /// Naming the room still separates them.
    func testNamingTheRoomSeparatesTwoLights() {
        XCTAssertEqual(LocalCapability.of("turn the bedroom light off", devices: [light, lamp]),
                       .device(id: "bedroom_main_light", command: .off))
        XCTAssertEqual(LocalCapability.of("desk lamp on", devices: [light, lamp]),
                       .device(id: "desk_lamp", command: .press),
                       "a push-button Bot takes a press whatever the sentence asked for")
    }

    /// A second device of a different kind does not make the one light ambiguous.
    func testADeviceOfAnotherKindDoesNotMakeTheLightAmbiguous() {
        XCTAssertEqual(LocalCapability.of("lights out", devices: [light, kettle]),
                       .device(id: "bedroom_main_light", command: .off))
    }

    /// "lights" and "light" are the same word to the owner, so they are the same word here.
    func testPluralAndSingularAreOneWord() {
        let plural = StandbyDevice([
            "id": "bedroom_main_light", "name": "Bedroom Lights", "room": "Bedroom", "kind": "light",
            "provider": "SwitchBot", "providerDeviceId": "C271D2A08E4F", "preferPress": false
        ])!

        XCTAssertEqual(LocalCapability.of("turn the bedroom light off", devices: [plural]),
                       .device(id: "bedroom_main_light", command: .off))
        XCTAssertEqual(LocalCapability.of("bedroom lights on", devices: [light]),
                       .device(id: "bedroom_main_light", command: .on))
    }

    /// A referent, with exactly one thing it could refer to.
    func testAPronounWorksWhenThereIsOnlyOneDevice() {
        XCTAssertEqual(LocalCapability.of("turn that off", devices: [light]),
                       .device(id: "bedroom_main_light", command: .off))
        XCTAssertNil(LocalCapability.of("turn that off", devices: [light, kettle]),
                     "with two devices a pronoun refers to nothing this can resolve")
    }

    /// "switch the bedroom light" asks for the device to be worked without saying which way.
    func testAVerbWithNoDirectionIsAToggle() {
        XCTAssertEqual(LocalCapability.of("switch the bedroom light", devices: [light]),
                       .deviceToggle(id: "bedroom_main_light"))
        XCTAssertEqual(LocalCapability.of("flip the light", devices: [light]),
                       .deviceToggle(id: "bedroom_main_light"))

        // A direction, when there is one, still wins over the verb.
        XCTAssertEqual(LocalCapability.of("switch the bedroom light on", devices: [light]),
                       .device(id: "bedroom_main_light", command: .on))
    }

    /// A Bot on a push button has one thing it can do, so a toggle is that thing.
    func testATogglePutToAPushButtonBotIsAPress() {
        XCTAssertEqual(LocalCapability.of("switch the desk lamp", devices: [lamp]),
                       .device(id: "desk_lamp", command: .press))
    }

    /// A question is still not a command, however short.
    func testAQuestionIsNeverACommand() {
        for sentence in ["is the light on", "what's the bedroom light doing", "are the lights on"] {
            XCTAssertNil(LocalCapability.of(sentence, devices: [light]), "\(sentence) is a question")
        }
    }

    /// Nothing learned, nothing claimed.
    func testWithNoBindingsNoSentenceIsADeviceCommand() {
        for sentence in ["lights out", "turn that off", "switch the bedroom light"] {
            XCTAssertNil(LocalCapability.of(sentence, devices: []))
        }
    }

    /// The waking rule still wins, because it was already the rule.
    func testTheMachineRulesAreUnchanged() {
        XCTAssertEqual(LocalCapability.of("wake my pc", devices: [light]), .wake(target: nil))
        XCTAssertEqual(LocalCapability.of("is my pc on", devices: [light]), .state(target: nil))
        XCTAssertEqual(LocalCapability.of("what's my phone battery", devices: [light]), .power(target: "phone"))
    }

    // MARK: The executor

    private func vendor(_ answer: @escaping (URLRequest) async throws -> (Data, URLResponse)) -> SwitchBotStandby.Wiring {
        var wiring = SwitchBotStandby.Wiring(send: answer)
        wiring.milliseconds = { 1_700_000_000_000 }
        wiring.nonce = { "11111111-2222-3333-4444-555555555555" }
        return wiring
    }

    private func reply(_ json: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8),
         HTTPURLResponse(url: URL(string: "https://api.switch-bot.com/v1.1/x")!,
                         statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private var credentials: SwitchBotCredentials { SwitchBotCredentials(token: "t", secret: "s") }

    /// Accepted then read back as off: that, and only that, is a confirmation.
    func testTheExecutorSendsThenReadsBack() async {
        var calls: [String] = []
        let wiring = vendor { request in
            calls.append(request.httpMethod ?? "")
            return request.httpMethod == "POST"
                ? self.reply(#"{"statusCode":100,"message":"success","body":{}}"#)
                : self.reply(#"{"statusCode":100,"message":"success","body":{"power":"off","battery":88}}"#)
        }

        let done = await StandbyExecutor.perform(.off, on: light, credentials: credentials, wiring: wiring)

        XCTAssertEqual(calls, ["POST", "GET"], "the command, then the read-back")
        XCTAssertEqual(done.confirmed, false)
        XCTAssertEqual(done.battery, 88)
        XCTAssertEqual(done.outcome, .confirmed(on: false))
    }

    /// A command the vendor took and a read that shows nothing stays at "sent".
    func testAcceptedWithNothingToConfirmAgainstStaysSent() async {
        let wiring = vendor { request in
            request.httpMethod == "POST"
                ? self.reply(#"{"statusCode":100,"message":"success","body":{}}"#)
                : self.reply(#"{"statusCode":100,"message":"success","body":{}}"#)
        }

        let done = await StandbyExecutor.perform(.press, on: lamp, credentials: credentials, wiring: wiring)

        XCTAssertNil(done.confirmed)
        XCTAssertEqual(done.outcome, .sent)
        XCTAssertFalse(done.sentence.lowercased().contains("confirm"),
                       "or rather: it says it cannot confirm, not that it did")
    }

    /// A hub that is not online never reaches the read-back at all.
    func testAnOfflineHubDoesNotGetReadBack() async {
        var calls = 0
        let wiring = vendor { _ in
            calls += 1
            return self.reply(#"{"statusCode":171,"message":"hub offline","body":{}}"#)
        }

        let done = await StandbyExecutor.perform(.off, on: light, credentials: credentials, wiring: wiring)

        XCTAssertEqual(calls, 1, "nothing to read back from a command that did not happen")
        XCTAssertNil(done.confirmed)
        XCTAssertTrue(done.sentence.contains("Hub"))
    }

    // MARK: Resolving a name, for Siri and Shortcuts

    func testADeviceIsFoundByIdThenNameThenPartOfAName() {
        XCTAssertEqual(StandbyExecutor.binding(named: "bedroom_main_light", in: [light, lamp])?.id, "bedroom_main_light")
        XCTAssertEqual(StandbyExecutor.binding(named: "Desk Lamp", in: [light, lamp])?.id, "desk_lamp")
        XCTAssertEqual(StandbyExecutor.binding(named: "desk", in: [light, lamp])?.id, "desk_lamp")
        XCTAssertEqual(StandbyExecutor.binding(named: "  BEDROOM LIGHT ", in: [light, lamp])?.id, "bedroom_main_light")
    }

    func testAPartialNameThatFitsTwoDevicesResolvesToNeither() {
        XCTAssertNil(StandbyExecutor.binding(named: "light", in: [light, lamp]),
                     "'light' is in both names, so it names neither")
        XCTAssertNil(StandbyExecutor.binding(named: "", in: [light]))
        XCTAssertNil(StandbyExecutor.binding(named: "greenhouse", in: [light]))
    }

    func testActingAloneNeedsBothACredentialAndABindingThisPhoneCanReach() {
        XCTAssertTrue(StandbyExecutor.canActAlone([light], credentials: credentials))
        XCTAssertFalse(StandbyExecutor.canActAlone([], credentials: credentials))
        XCTAssertFalse(StandbyExecutor.canActAlone([light], credentials: nil))
        XCTAssertFalse(StandbyExecutor.canActAlone([light], credentials: SwitchBotCredentials(token: "", secret: "s")))

        let other = StandbyDevice([
            "id": "hall", "name": "Hall", "kind": "light",
            "provider": "Hue", "providerDeviceId": "1", "preferPress": false
        ])!
        XCTAssertFalse(StandbyExecutor.canActAlone([other], credentials: credentials),
                       "a provider this phone cannot talk to is not a route")
    }

    func testSentinel() {}
}
