import XCTest
@testable import JARVIS

/// What this phone says about power - programme §13, §15, §18.
///
/// The hard part is not reading a battery; it is being honest about the one it cannot read. iOS
/// gives a third-party app its own level and gives it nothing at all about anything paired over
/// Bluetooth, so the AirPods row is deliberately a named device with no number and the reason why.
/// Several of these tests exist to stop that turning into a plausible figure later.
@MainActor
final class PowerReportingTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    private func reading(_ name: String, _ percent: Int?, _ charge: ChargeReading = .discharging,
                         id: String? = nil, ago: TimeInterval = 0, saving: Bool = false,
                         because: String? = nil) -> PowerReading {
        PowerReading(deviceId: id ?? name.lowercased(), name: name, percent: percent, charge: charge,
                     measuredAt: noon.addingTimeInterval(-ago), lowPowerMode: saving, because: because)
    }

    // MARK: The row that goes over the wire

    func testARowCarriesTheTimeItWasMeasuredAndNotTheTimeItIsSent() {
        let row = reading("iPhone", 63, ago: 600).row

        XCTAssertEqual(row["deviceId"] as? String, "iphone")
        XCTAssertEqual(row["percent"] as? Int, 63)
        XCTAssertEqual(row["charge"] as? String, "discharging")
        XCTAssertNotNil(row["measuredAt"] as? String)

        let stamp = ISO8601DateFormatter().date(from: row["measuredAt"] as! String)
        XCTAssertEqual(stamp?.timeIntervalSince1970 ?? 0,
                       noon.addingTimeInterval(-600).timeIntervalSince1970,
                       accuracy: 1)
    }

    /// No level means the key is absent rather than present and zero. Zero per cent is a reading.
    func testARowWithNoLevelSendsNoLevelRatherThanZero() {
        let row = reading("AirPods Pro", nil, .unknown, because: "iOS doesn't give an app the battery.").row

        XCTAssertNil(row["percent"])
        XCTAssertEqual(row["because"] as? String, "iOS doesn't give an app the battery.")
    }

    func testTheChargeStatesUseThePCsOwnSpelling() {
        XCTAssertEqual(ChargeReading.charging.rawValue, "charging")
        XCTAssertEqual(ChargeReading.discharging.rawValue, "discharging")
        XCTAssertEqual(ChargeReading.full.rawValue, "full")
        XCTAssertEqual(ChargeReading.mains.rawValue, "mains")
        XCTAssertEqual(ChargeReading.unknown.rawValue, "unknown")
    }

    // MARK: How it is said with the PC off

    func testAFreshReadingIsSaidInThePresentTense() {
        XCTAssertEqual(PowerReporter.say(reading("iPhone", 63), now: noon),
                       "iPhone is at 63 per cent, sir.")
    }

    func testChargingAndLowPowerModeAreSaidWhenTrue() {
        XCTAssertTrue(PowerReporter.say(reading("iPhone", 40, .charging), now: noon).contains("charging"))
        XCTAssertTrue(PowerReporter.say(reading("iPhone", 100, .full), now: noon).contains("full"))
        XCTAssertTrue(PowerReporter.say(reading("iPhone", 15, saving: true), now: noon).contains("low power mode"))
        XCTAssertFalse(PowerReporter.say(reading("iPhone", 80), now: noon).contains("low power mode"))
    }

    /// A percentage in the present tense is a claim about now, and a reading taken an hour ago
    /// cannot support one. The same rule the PC applies, for the same reason.
    func testAnOldReadingIsSaidAsAMemory() {
        let said = PowerReporter.say(reading("iPhone", 60, ago: 3600), now: noon)

        XCTAssertTrue(said.contains("was at 60 per cent"), said)
        XCTAssertTrue(said.contains("ago"), said)
        XCTAssertFalse(said.contains("is at"), said)
    }

    func testSomethingWithNoLevelIsSaidAsSuchWithItsReason() {
        let said = PowerReporter.say(
            reading("AirPods Pro", nil, .unknown, because: "iOS doesn't tell apps."), now: noon)

        XCTAssertTrue(said.contains("no battery reading"), said)
        XCTAssertTrue(said.contains("iOS doesn't tell apps"), said)
        XCTAssertFalse(said.contains("per cent"), said)
    }

    func testNothingReadableIsSaidPlainlyRatherThanAsAnEmptyList() {
        XCTAssertTrue(PowerReporter.sayAll([], now: noon).contains("can't read anything's battery"))
    }

    // MARK: Picking a device out of a question

    func testNamingNothingMeansEverything() {
        let all = [reading("iPhone", 63), reading("AirPods Pro", nil)]

        XCTAssertEqual(PowerReporter.matching(nil, in: all).count, 2)
        XCTAssertEqual(PowerReporter.matching("  ", in: all).count, 2)
    }

    func testAPartOfTheNameFindsIt() {
        let all = [reading("iPhone", 63), reading("AirPods Pro", nil)]

        XCTAssertEqual(PowerReporter.matching("airpods", in: all).map(\.name), ["AirPods Pro"])
        XCTAssertEqual(PowerReporter.matching("AIRPODS PRO", in: all).map(\.name), ["AirPods Pro"])
    }

    func testSomethingNotThereFindsNothingRatherThanTheWrongDevice() {
        let all = [reading("iPhone", 63), reading("AirPods Pro", nil)]

        XCTAssertTrue(PowerReporter.matching("tractor", in: all).isEmpty)
    }

    // MARK: Reading the question

    /// The topic word is the discriminator, as it is on the PC.
    func testABatteryQuestionIsThisPhonesToAnswer() {
        for said in ["what's my phone's battery", "how's the battery", "is my phone charging",
                     "battery level", "how much charge is left", "what's the battery on my airpods"] {
            guard case .power = LocalCapability.of(said) else {
                return XCTFail("\(said) was not read as a battery question")
            }
        }
    }

    func testABatteryQuestionNamesWhatItNamed() {
        guard case .power(let target) = LocalCapability.of("what's the battery on my airpods") else {
            return XCTFail("not read as a battery question")
        }
        XCTAssertEqual(target, "airpods")

        guard case .power(let none) = LocalCapability.of("battery level") else {
            return XCTFail("not read as a battery question")
        }
        XCTAssertNil(none)
    }

    func testTheActionNameIsTheOneTheCatalogueWouldUse() {
        XCTAssertEqual(LocalCapability.power(target: nil).action, "device.power.battery")
        XCTAssertEqual(LocalCapability.power(target: "airpods").target, "airpods")
    }

    /// Without the topic word it is not this rule's business, and some of these are other rules'.
    func testAQuestionThatIsNotAboutABatteryIsLeftAlone() {
        for said in ["what's my pc doing", "turn the lights off", "what's the weather",
                     "how are you", "what's on my calendar"] {
            if case .power = LocalCapability.of(said) {
                XCTFail("\(said) was taken as a battery question")
            }
        }
    }

    /// "Is my PC on" is the machine-state question and must stay one: both sentences name a
    /// machine, and only one of them is about power.
    func testAskingWhetherThePCIsOnIsStillTheMachineQuestion() {
        guard case .state = LocalCapability.of("is my pc on") else {
            return XCTFail("the machine question was taken by the battery rule")
        }
    }

    /// "Wake my PC" carries a power word. It is a command, not a question, and must still wake.
    func testWakingIsStillWaking() {
        guard case .wake = LocalCapability.of("wake my pc") else {
            return XCTFail("waking was taken by the battery rule")
        }
        guard case .wake = LocalCapability.of("turn the pc on") else {
            return XCTFail("switching the PC on was taken by the battery rule")
        }
    }

    /// A command about charging is nobody's request here - a phone cannot charge itself.
    func testACommandAboutChargingIsNotAQuestionAboutIt() {
        for said in ["turn the charging off", "stop charging my phone", "plug the phone in"] {
            if case .power = LocalCapability.of(said) {
                XCTFail("\(said) was taken as a question")
            }
        }
    }

    /// Two names and the sentence is about something this reading cannot pick out; the PC, which
    /// holds every node's readings, is the better place for it.
    func testASentenceNamingTwoThingsGoesToThePC() {
        XCTAssertNil(LocalCapability.of("what's the battery on the airpods and the headset"))
    }

    // MARK: Sending only what moved

    func testOnlyChangedReadingsAreSent() async {
        let reporter = PowerReporter()
        var sent: [[PowerReading]] = []
        reporter.send = { sent.append($0) }

        await reporter.report([reading("iPhone", 63)])
        XCTAssertEqual(sent.count, 1)

        // The same percentage again is a heartbeat, not a change.
        await reporter.report([reading("iPhone", 63, ago: 30)])
        XCTAssertEqual(sent.count, 1)

        await reporter.report([reading("iPhone", 62, ago: 60)])
        XCTAssertEqual(sent.count, 2)
    }

    func testAChangeOfChargeStateIsAChange() async {
        let reporter = PowerReporter()
        var sent: [[PowerReading]] = []
        reporter.send = { sent.append($0) }

        await reporter.report([reading("iPhone", 63)])
        await reporter.report([reading("iPhone", 63, .charging)])

        XCTAssertEqual(sent.count, 2, "plugging it in is worth telling the PC about")
    }
    // MARK: Asking the PC - the kind, which is the thing that broke

    /// The read has its own kind, and it is not the shut-down action's.
    func testThePhoneAsksForReadingsRatherThanForTheShutDownAction() async {
        var asked: [String] = []

        await PowerReporter().askTheOthers { kind in
            asked.append(kind)
            return BridgeMessage(kind: kind, id: "1", body: ["devices": []])
        }

        // Bare "power" is the PC's sleep, restart and shut-down action. Asking it for readings
        // reached the action handler, which rejected the request, and this page went blank.
        XCTAssertEqual(asked, ["power.all"])
    }

    func testRowsFromThePcArriveAndThisPhonesOwnAreLeftToTheLocalReading() async {
        let reporter = PowerReporter()

        await reporter.askTheOthers { kind in
            BridgeMessage(kind: kind, id: "1", body: ["devices": [self.desktopRow]])
        }

        XCTAssertEqual(reporter.elsewhere.map(\.deviceId), ["desktop"])
    }

    /// A refusal must not be read as "every other node has no battery".
    ///
    /// The guard checks the reply's kind as well as the request's, because a PC that has never
    /// heard of the kind answers "failed" with an empty body - and reading that as an answer is
    /// what would silently clear a page that was previously right.
    func testARefusalLeavesWhatThePhoneAlreadyHad() async {
        let reporter = PowerReporter()

        await reporter.askTheOthers { kind in
            BridgeMessage(kind: kind, id: "1", body: ["devices": [self.desktopRow]])
        }

        XCTAssertEqual(reporter.elsewhere.map(\.deviceId), ["desktop"])

        await reporter.askTheOthers { _ in
            BridgeMessage(kind: "failed", id: "2", body: ["message": "The PC does not know that."])
        }

        // Still there. This is the assertion that would have caught the wrong kind, because the
        // symptom of asking for the action was a refusal arriving where an answer was expected.
        XCTAssertEqual(reporter.elsewhere.map(\.deviceId), ["desktop"])
    }

    /// One row in the shape the PC's `power.all` reply actually sends.
    private var desktopRow: [String: Any] {
        ["deviceId": "desktop", "name": "DESKTOP", "percent": 100, "charge": "mains",
         "reporter": "DESKTOP", "freshness": "Live", "said": "the desk is on mains",
         "measuredAt": ISO8601DateFormatter().string(from: noon)]
    }

}
