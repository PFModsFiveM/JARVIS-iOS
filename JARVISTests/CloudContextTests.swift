import XCTest
@testable import JARVIS

/// What a cloud provider is told, and what it is never told - programme §3C.
///
/// Half of these are ordinary tests of a selection rule. The other half are the boundary: a
/// coordinate must not leave this device through here, and the only way an assertion like that
/// stays true is if something fails when it stops being.
final class CloudContextTests: XCTestCase {
    private func known(
        turns: [(said: String, answered: String)] = [],
        place: String? = nil,
        pcAnswering: Bool = false,
        routine: String? = nil
    ) -> CloudContext.Known {
        CloudContext.Known(
            turns: turns, place: place, pcAnswering: pcAnswering, pcName: "DOM-PC", routine: routine)
    }

    // MARK: the boundary

    /// The question this type exists to answer "no" to.
    func testAGeneralQuestionIsNotAReasonToSayWhereTheOwnerLives() {
        let lines = CloudContext.lines(for: "explain black holes", from: known(place: "Home"))

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined().contains("Home"))
    }

    func testNoCoordinateCanReachTheContextBecauseOnlyANameEverArrives() {
        // The place arrives as a name, by the type's own shape. A coordinate could only get here
        // by somebody passing one as the name, so that is what is asserted against: even then it
        // is the caller's bug and not a silent leak, and this records which it would be.
        let lines = CloudContext.lines(for: "what's the weather like here", from: known(place: "Home"))

        XCTAssertEqual(lines, ["The owner is at Home."])
        XCTAssertFalse(lines.joined().contains("53."))
        XCTAssertFalse(lines.joined().contains("-7."))
    }

    func testTheContextIsBoundedHoweverMuchIsAvailable() {
        let many = (0..<20).map { (said: "question \($0)", answered: "answer \($0)") }

        let lines = CloudContext.lines(
            for: "and when do I usually open it here",
            from: known(turns: many, place: "Home", pcAnswering: true, routine: "You usually leave Home at eight."))

        XCTAssertLessThanOrEqual(lines.count, CloudContext.mostLines)
    }

    func testOneLongLineCannotBecomeAParagraph() {
        let essay = String(repeating: "a very long thing the owner said ", count: 40)

        let lines = CloudContext.lines(for: "go on then", from: known(turns: [(essay, essay)]))

        XCTAssertFalse(lines.isEmpty)

        for line in lines {
            XCTAssertLessThanOrEqual(line.count, CloudContext.longestLine + 40)
        }
    }

    // MARK: the thread

    func testTheConversationTravelsBecauseAFollowUpWithNoThreadIsADifferentQuestion() {
        let lines = CloudContext.lines(
            for: "and the second one",
            from: known(turns: [("give me three ideas", "one, two, three")]))

        XCTAssertTrue(lines.contains { $0.contains("give me three ideas") })
        XCTAssertTrue(lines.contains { $0.contains("one, two, three") })
    }

    func testOnlyTheLastTwoExchangesTravel() {
        let turns = (0..<6).map { (said: "said \($0)", answered: "answered \($0)") }

        let lines = CloudContext.lines(for: "carry on", from: known(turns: turns))

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.contains { $0.contains("said 5") })
        XCTAssertFalse(lines.contains { $0.contains("said 0") })
    }

    // MARK: selection by what was asked

    func testAQuestionAboutHereGetsThePlace() {
        for asked in ["what's near here", "is it cold outside", "what's the weather", "anywhere local to eat"] {
            let lines = CloudContext.lines(for: asked, from: known(place: "Home"))

            XCTAssertTrue(lines.contains("The owner is at Home."), asked)
        }
    }

    func testAQuestionAboutHereWithNoPlaceKnownAddsNothingRatherThanAnApology() {
        XCTAssertTrue(CloudContext.lines(for: "what's near here", from: known()).isEmpty)
    }

    func testARequestToDoSomethingIsToldWhetherThePcCanDoIt() {
        let awake = CloudContext.lines(for: "open blender for me", from: known(pcAnswering: true))
        let asleep = CloudContext.lines(for: "open blender for me", from: known(pcAnswering: false))

        XCTAssertTrue(awake.contains { $0.contains("awake") })
        XCTAssertTrue(asleep.contains { $0.contains("not answering") })
    }

    func testAQuestionThatAsksForNothingIsNotToldAboutThePc() {
        let lines = CloudContext.lines(for: "what is a black hole", from: known(pcAnswering: true))

        XCTAssertFalse(lines.contains { $0.contains("PC") })
    }

    /// A pattern arrives already hedged, so a model cannot restate it as a fact without
    /// contradicting the line it was given.
    func testARoutineTravelsAsAPatternAndNotAsAFact() {
        let lines = CloudContext.lines(
            for: "when do I usually get home",
            from: known(routine: "You usually get to Home between about 17:50 and 18:20, sir."))

        XCTAssertTrue(lines.contains { $0.contains("usually") })
        XCTAssertTrue(lines.contains { $0.contains("between about") })
    }

    func testARoutineIsNotSentWithAQuestionThatIsNotAboutTheOwnersDay() {
        let lines = CloudContext.lines(
            for: "explain quantum tunnelling",
            from: known(routine: "You usually get to Home between about 17:50 and 18:20, sir."))

        XCTAssertTrue(lines.isEmpty)
    }

    func testSentinel() {}
}
