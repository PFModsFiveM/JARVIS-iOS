import XCTest
@testable import JARVIS

/// The register Mobile JARVIS speaks in - programme §11.
///
/// These assert across every phrase at once rather than one test per sentence, which is the point
/// of there being a list: a phrase added without a thought about how it reads fails the suite
/// instead of shipping. Before this, the phone said "I can only wake DOM-PC from home, sir" in one
/// place and "I don't know a device by that name." in another, and "That is not a card address."
/// with nobody addressed at all.
final class MobilePhraseTests: XCTestCase {

    /// One node of JARVIS does not speak in three voices.
    func testEveryPhraseAddressesTheOwner() {
        for phrase in MobilePhrases.everything {
            XCTAssertTrue(phrase.contains("sir"), "nobody is addressed in: \(phrase)")
        }
    }

    func testNoPhraseIsEmptyOrUnfinished() {
        for phrase in MobilePhrases.everything {
            XCTAssertFalse(phrase.isEmpty)
            XCTAssertFalse(phrase.contains("()"), "an argument went missing in: \(phrase)")
            XCTAssertFalse(phrase.contains("  "), "a gap was left by an empty argument in: \(phrase)")
            XCTAssertTrue(phrase.hasSuffix(".") || phrase.hasSuffix("?"), "unfinished: \(phrase)")
        }
    }

    /// A technical failure is not what the owner is told. A socket that refused a connection is a
    /// machine that is not answering, which is both truer and more useful.
    func testNoPhraseLeaksATechnicalFailure() {
        let leaks = ["error", "exception", "refused", "timeout", "nil", "null", "failed",
                     "socket", "http", "0x"]

        for phrase in MobilePhrases.everything {
            for leak in leaks {
                XCTAssertFalse(phrase.lowercased().contains(leak), "\(leak) reached the owner in: \(phrase)")
            }
        }
    }

    /// §"Never say 'Done, sir' just because a request was sent."
    func testNoPhraseClaimsSomethingHappenedWithoutHavingSeenIt() {
        for phrase in MobilePhrases.everything {
            let said = phrase.lowercased()
            XCTAssertFalse(said.hasPrefix("done"), phrase)
            XCTAssertFalse(said.contains("all done"), phrase)
            XCTAssertFalse(said.contains("i've switched"), phrase)
            XCTAssertFalse(said.contains("i've turned"), phrase)
        }
    }

    /// Sent and done are different facts, and the sentence says which it is.
    func testACommandTheVendorTookButNobodyConfirmedSaysSo() {
        let sent = MobilePhrases.sentButUnconfirmed("Bedroom Light", "")

        XCTAssertTrue(sent.contains("sent"), sent)
        XCTAssertTrue(sent.contains("can't confirm"), sent)
        XCTAssertFalse(sent.lowercased().contains(" is on"), sent)
        XCTAssertFalse(sent.lowercased().contains(" is off"), sent)
    }

    /// And a command that *was* confirmed says that instead, without hedging.
    func testAConfirmedSwitchIsSaidPlainly() {
        XCTAssertEqual(MobilePhrases.switchedOn("Bedroom Light"), "Bedroom Light is on, sir.")
        XCTAssertEqual(MobilePhrases.switchedOff("Bedroom Light"), "Bedroom Light is off, sir.")
    }

    /// A wake request is a request. The protocol has no reply and UDP is not acknowledged, so the
    /// machine being awake is established by it answering and by nothing else.
    func testAWakeRequestIsNeverAWokenMachine() {
        let said = MobilePhrases.sendingWake("DOM-PC")

        XCTAssertTrue(said.contains("Sending"), said)
        XCTAssertFalse(said.lowercased().contains("is awake"), said)
        XCTAssertFalse(said.lowercased().contains("woken"), said)
        XCTAssertFalse(said.lowercased().contains("switched on"), said)
    }

    /// Where a number was not measured, the sentence says so rather than supplying one.
    func testAMissingBatteryReadingNeverCarriesANumber() {
        for said in [MobilePhrases.noBatteryReading("AirPods Pro", because: "iOS doesn't tell apps."),
                     MobilePhrases.noBatteryReading("AirPods Pro", because: nil),
                     MobilePhrases.nothingReadable()] {
            XCTAssertFalse(said.contains("per cent"), said)
            XCTAssertNil(said.rangeOfCharacter(from: .decimalDigits), said)
        }
    }

    func testAReasonIsPassedThroughWhenThereIsOne() {
        let said = MobilePhrases.noBatteryReading("AirPods Pro", because: "iOS doesn't tell apps.")

        XCTAssertTrue(said.contains("AirPods Pro"), said)
        XCTAssertTrue(said.contains("iOS doesn't tell apps"), said)
    }

    func testOneMinuteIsSingularAndTwoArePlural() {
        XCTAssertTrue(MobilePhrases.batteryThen("iPhone", 60, minutes: 1).contains("1 minute ago"))
        XCTAssertTrue(MobilePhrases.batteryThen("iPhone", 60, minutes: 7).contains("7 minutes ago"))
    }

    /// The machine is called by its name wherever one is known, rather than "your PC".
    func testTheMachineIsCalledByItsName() {
        let named = [MobilePhrases.wakingIsOff("DOM-PC"), MobilePhrases.cardUnknown("DOM-PC"),
                     MobilePhrases.onlyFromHome("DOM-PC"), MobilePhrases.sendingWake("DOM-PC"),
                     MobilePhrases.thePCsAndItCanBeWoken("DOM-PC"), MobilePhrases.cannotReachAtAll("DOM-PC"),
                     MobilePhrases.nobodySignedIn("DOM-PC"), MobilePhrases.lockedWithoutJarvis("DOM-PC")]

        for said in named {
            XCTAssertTrue(said.contains("DOM-PC"), said)
        }
    }

    /// The three answers for a request that belongs to the PC are three different answers, because
    /// what this phone can offer about it is different in each case.
    func testTheThreeAnswersAboutAnAbsentPCAreDistinct() {
        let three = Set([MobilePhrases.thePCsAndItCanBeWoken("DOM-PC"),
                         MobilePhrases.thePCsAndItCannotBeWoken("DOM-PC"),
                         MobilePhrases.thePCsAndNothingCanBeDone("DOM-PC")])

        XCTAssertEqual(three.count, 3)
    }

    func testEveryPhraseIsSaidOnlyOnce() {
        let all = MobilePhrases.everything

        // Two identical sentences from two functions means one of them is a duplicate waiting to
        // drift away from the other, which is what this file exists to stop.
        XCTAssertEqual(all.count, Set(all).count, "two phrases are identical")
    }
}
