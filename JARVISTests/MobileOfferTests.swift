import XCTest

@testable import JARVIS

/// Picking one of the things JARVIS last read out, on the phone - priority §15.
///
/// The case: results read out at the desk in the evening, "open the second one" on the phone
/// later with the desk asleep. Before this the phone had never heard of them, because the shared
/// conversation was only ever written by the bridge when a *phone* filed a turn.
///
/// And the line the brief draws: knowing which one the owner means is not having the tab. The
/// phone can recognise an offer and open its address. It cannot drive a browser on another
/// machine, and nothing here pretends otherwise.
final class MobileOfferTests: XCTestCase {

    private func results() -> [MobileOffer] {
        [
            MobileOffer(position: 1, title: "Hard Surface Basics", address: "https://youtu.be/aaa"),
            MobileOffer(position: 2, title: "Bevels Explained", address: "https://youtu.be/bbb"),
            MobileOffer(position: 3, title: "Boolean Cleanup", address: "https://youtu.be/ccc")
        ]
    }

    // MARK: which one

    func testAnOrdinalPicksThatPosition() {
        guard case .one(let picked) = MobileOffers.pick("open the second one", from: results()) else {
            return XCTFail("the second one is not ambiguous")
        }

        XCTAssertEqual(picked.title, "Bevels Explained")
    }

    func testTheLastOneIsTheEndOfTheListRatherThanANumber() {
        guard case .one(let picked) = MobileOffers.pick("play the last one", from: results()) else {
            return XCTFail("the last one is a position")
        }

        XCTAssertEqual(picked.title, "Boolean Cleanup")
    }

    func testATitleCanPickItWithoutANumber() {
        guard case .one(let picked) = MobileOffers.pick("open the bevels video", from: results()) else {
            return XCTFail("one title matched")
        }

        XCTAssertEqual(picked.title, "Bevels Explained")
    }

    func testTwoTitlesThatFitEquallyWellIsAQuestion() {
        let offers = [
            MobileOffer(position: 1, title: "Bevels Explained", address: "https://a"),
            MobileOffer(position: 2, title: "Bevels In Depth", address: "https://b")
        ]

        guard case .ambiguous(let between) = MobileOffers.pick("open the bevels one", from: offers) else {
            return XCTFail("two fit equally well")
        }

        XCTAssertEqual(between.count, 2)
        XCTAssertTrue(MobileOffers.whichOne(between).contains("Bevels Explained"))
    }

    func testAPositionWithNothingListLikeAboutItIsNotTakenAsAList() {
        // The PC draws the same line: "first" and "top" are ordinary words, and "play top gun" is
        // not about a list. One of the words a list is made of has to be there.
        guard case .none = MobileOffers.pick("play top gun", from: results()) else {
            return XCTFail("top gun is a film")
        }

        guard case .none = MobileOffers.pick("open the second", from: results()) else {
            return XCTFail("a bare ordinal is not enough")
        }
    }

    func testASentenceAboutSomethingElseEntirelyIsNotAboutTheList() {
        // This runs before the ordinary routing, so taking a request that was about something else
        // would answer the wrong question confidently. Every one of these must fall through.
        for said in [
            "what's the weather",
            "turn the bedroom light on",
            "wake my pc",
            "how are you",
            "what's on my calendar"
        ] {
            guard case .none = MobileOffers.pick(said, from: results()) else {
                return XCTFail("\(said) is not about the list")
            }
        }
    }

    func testWithNothingOfferedNothingIsPicked() {
        guard case .none = MobileOffers.pick("open the second one", from: []) else {
            return XCTFail("there is no list")
        }
    }

    func testAPositionNobodyOfferedIsNotInvented() {
        guard case .none = MobileOffers.pick("open the fifth one", from: results()) else {
            return XCTFail("there were three")
        }
    }

    // MARK: what may be claimed about it

    func testAnOfferWithAnAddressCanBeOpenedHere() {
        XCTAssertTrue(MobileOffers.reopenable(results()[1]))
    }

    func testAnOfferWithNothingToOpenIsNotPretendedOtherwise() {
        XCTAssertFalse(MobileOffers.reopenable(MobileOffer(position: 1, title: "A crane in the corner", address: nil)))
        XCTAssertFalse(MobileOffers.reopenable(MobileOffer(position: 1, title: "A file", address: "file:///C:/x.blend")))
        XCTAssertFalse(MobileOffers.reopenable(MobileOffer(position: 1, title: "Nonsense", address: "not a url")))
    }

    func testOpeningItHereIsNotTheSameAsHavingTheTab() {
        let said = MobileOffers.because(results()[1], pcName: "DOM-PC")

        XCTAssertTrue(said.contains("Opening"))
        XCTAssertTrue(said.contains("still on DOM-PC"))
    }

    func testSomethingWithNoAddressSaysThereIsNothingToOpen() {
        let said = MobileOffers.because(
            MobileOffer(position: 2, title: "A crane in the corner", address: nil), pcName: "DOM-PC")

        XCTAssertTrue(said.contains("nothing to open"))
        XCTAssertFalse(said.contains("Opening"))
    }

    // MARK: keeping them for when the desk is asleep

    @MainActor
    func testWhatWasOfferedSurvivesForTheWindow() {
        let memory = MobileOfferMemory(defaults: scratch())
        let when = Date()

        memory.hold(results(), from: "DOM-PC", at: when)

        XCTAssertEqual(memory.current(now: when.addingTimeInterval(60)).count, 3)
        XCTAssertEqual(memory.from, "DOM-PC")
    }

    @MainActor
    func testAListOlderThanTheWindowIsNotResolvedAgainst() {
        // "The second one" twelve hours later is almost certainly about something else, and
        // resolving it against last night's results would be worse than not resolving it.
        let memory = MobileOfferMemory(defaults: scratch())
        let when = Date()

        memory.hold(results(), from: "DOM-PC", at: when)

        XCTAssertTrue(memory.current(now: when.addingTimeInterval(MobileOffers.resolvesFor + 1)).isEmpty)
    }

    @MainActor
    func testTheOffersSurviveTheAppBeingRestarted() {
        // The whole point of keeping them here: the moment the owner needs them is the moment the
        // PC is asleep, so fetching on demand would mean it only worked while the desk was up.
        let defaults = scratch()
        let when = Date()

        MobileOfferMemory(defaults: defaults).hold(results(), from: "DOM-PC", at: when)

        let after = MobileOfferMemory(defaults: defaults)

        XCTAssertEqual(after.current(now: when.addingTimeInterval(60)).count, 3)
        XCTAssertEqual(after.from, "DOM-PC")
    }

    @MainActor
    func testAnEmptyListIsAnAnswerAndClearsWhatWasHeld() {
        // The desk's window passed. Saying "nothing" is right; keeping yesterday's is not.
        let defaults = scratch()
        let memory = MobileOfferMemory(defaults: defaults)

        memory.hold(results(), from: "DOM-PC")
        memory.hold([], from: "DOM-PC")

        XCTAssertTrue(memory.current().isEmpty)
        XCTAssertTrue(MobileOfferMemory(defaults: defaults).current().isEmpty)
    }

    @MainActor
    func testOnlyAHandfulIsKept() {
        let memory = MobileOfferMemory(defaults: scratch())

        let many = (1...20).map { MobileOffer(position: $0, title: "Result \($0)", address: "https://x/\($0)") }

        memory.hold(many, from: "DOM-PC")

        XCTAssertEqual(memory.current().count, MobileOfferMemory.most)
    }

    @MainActor
    func testForgettingLeavesNothingBehind() {
        let defaults = scratch()
        let memory = MobileOfferMemory(defaults: defaults)

        memory.hold(results(), from: "DOM-PC")
        memory.forget()

        XCTAssertTrue(memory.current().isEmpty)
        XCTAssertTrue(MobileOfferMemory(defaults: defaults).current().isEmpty)
    }

    // MARK: the window both nodes use

    func testTheWindowMatchesThePCs() {
        // The PC resolves for twenty minutes. Two different windows would mean "the second one"
        // working on one body of JARVIS and not the other, which is the thing this is for.
        XCTAssertEqual(MobileOffers.resolvesFor, 20 * 60)
    }

    private func scratch() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "jarvis.offers.tests.\(UUID().uuidString)")!

        defaults.removePersistentDomain(forName: defaults.description)

        return defaults
    }
}
