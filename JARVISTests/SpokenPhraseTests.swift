import XCTest

@testable import JARVIS

/// What JARVIS's own voice keeps, and what it refuses to keep - priority §14.
///
/// The brief's instruction is not to embed dynamic percentages or numbers in static cached
/// phrases. What made that more than a style note: every sentence the PC rendered was kept,
/// keyed on its words, in a cache of a hundred and twenty entries whose whole purpose is to hold
/// the handful of things JARVIS says constantly so its own voice survives the desk going to
/// sleep. "Your iPhone is at forty-seven per cent, sir." is true for a minute, will never be
/// asked for in those words again, and takes one of those slots. A hundred battery readings and
/// the bank is gone.
final class SpokenPhraseTests: XCTestCase {

    // MARK: what is a phrase

    func testAnOrdinaryPhraseIsWorthKeeping() {
        XCTAssertTrue(SpokenPhrase.worthKeeping("Right away, sir."))
        XCTAssertTrue(SpokenPhrase.worthKeeping("That's on, sir."))
        XCTAssertNil(SpokenPhrase.whyNotKept("Right away, sir."))
    }

    func testASentenceWithAPercentageIsNotKept() {
        let said = "iPhone is at 47 per cent, sir."

        XCTAssertFalse(SpokenPhrase.worthKeeping(said))
        XCTAssertTrue(SpokenPhrase.whyNotKept(said)?.contains("value") ?? false)
    }

    func testASentenceWithAnyDigitAtAllIsNotKept() {
        // Counts, times, dates and minutes-ago, all of which the phone says. One rule covers them
        // because they fail for the same reason: the sentence is only true for a while.
        for said in [
            "3 observations are waiting to reach your PC, sir.",
            "iPhone was at 60 per cent, sir, 7 minutes ago.",
            "I'm 12 behind what your PC has, sir, and catching up.",
            "Your alarm is set for 7:30, sir."
        ] {
            XCTAssertFalse(SpokenPhrase.worthKeeping(said), said)
        }
    }

    func testASentenceWithAUnitSymbolIsNotKept() {
        XCTAssertFalse(SpokenPhrase.worthKeeping("It's twenty-one °C outside, sir."))
        XCTAssertFalse(SpokenPhrase.worthKeeping("That came to £ forty, sir."))
    }

    func testABespokeAnswerIsNotKeptEvenWithoutANumberInIt() {
        let essay = String(repeating: "a sentence about the render, ", count: 12)

        XCTAssertFalse(SpokenPhrase.worthKeeping(essay))
        XCTAssertTrue(SpokenPhrase.whyNotKept(essay)?.contains("bespoke") ?? false)
    }

    func testNothingIsNotKept() {
        XCTAssertFalse(SpokenPhrase.worthKeeping("   "))
        XCTAssertNotNil(SpokenPhrase.whyNotKept(""))
    }

    // MARK: the bank itself

    func testEveryPhraseInTheBankIsWorthKeeping() {
        // The invariant that keeps the two halves consistent: if a kind were ever written with a
        // number in it, the cache would refuse to hold it and the bank could never be warmed -
        // silently, and only noticeable as JARVIS losing its voice offline.
        for kind in SpokenKind.allCases {
            XCTAssertTrue(SpokenPhrase.worthKeeping(kind.words), "\(kind.rawValue): \(kind.words)")
        }
    }

    func testTheBankKnowsItsOwnSentences() {
        XCTAssertTrue(SpokenPhrase.isOneOfTheBanks(SpokenKind.rightAway.words))
        XCTAssertFalse(SpokenPhrase.isOneOfTheBanks("Something JARVIS said once."))
    }

    func testTheBankCoversWhatThePhoneSaysForItselfWithTheDeskAsleep() {
        // Priority §3 made the phone answer pleasantries on its own, and the moment it answers for
        // itself is exactly the moment the PC cannot render for it. A pleasantry in the phone's
        // own British voice is a different assistant saying hello.
        let bank = Set(SpokenKind.allCases.map(\.words))

        for said in [
            MobilePhrases.greeting(),
            MobilePhrases.hereAndListening(),
            MobilePhrases.howIAm(),
            MobilePhrases.welcome(),
            MobilePhrases.untilLater()
        ] {
            XCTAssertTrue(bank.contains(said), said)
        }
    }

    func testThePhrasesTakenFromMobilePhrasesAreTheSameStringsBothPlaces() {
        // Byte-identical or the cache lookup misses, which is the whole reason there is one list.
        XCTAssertEqual(SpokenKind.greeting.words, MobilePhrases.greeting())
        XCTAssertEqual(SpokenKind.goodbye.words, MobilePhrases.untilLater())
        XCTAssertEqual(SpokenKind.noSuchDevice.words, MobilePhrases.noSuchDevice())
    }

    func testEveryKindHasWordsAndNoTwoKindsShareThem() {
        let words = SpokenKind.allCases.map(\.words)

        XCTAssertEqual(Set(words).count, words.count)
        XCTAssertFalse(words.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: the sentences the phone actually says

    func testThePhrasesWithValuesInThemAreTheOnesRefused() {
        // Read off MobilePhrases rather than invented here, so a phrase added with a number in it
        // is covered by this without anybody remembering to add it.
        let withValues = MobilePhrases.everything.filter { !SpokenPhrase.worthKeeping($0) }

        XCTAssertFalse(withValues.isEmpty, "the battery and sync phrases carry numbers")

        for said in withValues {
            XCTAssertNotNil(SpokenPhrase.whyNotKept(said), said)
        }
    }
}
