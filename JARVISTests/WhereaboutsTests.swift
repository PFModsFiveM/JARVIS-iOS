import XCTest
@testable import JARVIS

/// What the phone keeps of where it has been, and what it throws away.
///
/// The rules are arithmetic on purpose: a location manager cannot be driven from a test, and the
/// decisions worth proving - is this reading worth keeping, how many do we hold for a PC that is
/// not answering - do not need one. They are the same rules the PC's own trail applies, and the two
/// being the same is what keeps a phone's queue from filling with a still afternoon that the PC
/// would then discard anyway.
final class WhereaboutsTests: XCTestCase {
    private static let morning = Date(timeIntervalSince1970: 1_790_000_000)

    /// The owner's home, and the arithmetic of moving away from it.
    private func at(
        _ minutes: Double,
        latitude: Double = 53.4084,
        longitude: Double = -2.9916,
        accuracy: Double = 12
    ) -> Whereabouts {
        Whereabouts(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy,
            at: Self.morning.addingTimeInterval(minutes * 60))
    }

    func testTheFirstReadingIsAlwaysWorthKeeping() {
        XCTAssertTrue(WhereaboutsRules.worthKeeping(at(0), after: nil))
    }

    func testAStillPhoneIsNotKeptOverAndOver() {
        let first = at(0)

        XCTAssertFalse(WhereaboutsRules.worthKeeping(at(1), after: first))
        XCTAssertFalse(WhereaboutsRules.worthKeeping(at(5), after: first))
    }

    func testButAStillPhoneIsKeptEveryNowAndThen() {
        XCTAssertTrue(WhereaboutsRules.worthKeeping(at(10), after: at(0)))
    }

    func testMovingIsWorthKeeping() {
        // Roughly a kilometre north.
        XCTAssertTrue(WhereaboutsRules.worthKeeping(at(1, latitude: 53.4174), after: at(0)))
    }

    func testAReadingTooVagueToMeanAnythingIsNotKept() {
        // Half a kilometre is a phone guessing from cell towers indoors: not evidence of being
        // anywhere in particular.
        XCTAssertFalse(WhereaboutsRules.worthKeeping(at(30, accuracy: 800), after: at(0)))
        XCTAssertFalse(WhereaboutsRules.worthKeeping(at(0, accuracy: 800), after: nil))
    }

    func testDistanceIsRightToWithinAFewMetres() {
        // A tenth of a degree of latitude is about 11.1 km anywhere on earth.
        let metres = WhereaboutsRules.metres(at(0), at(0, latitude: 53.5084))

        XCTAssertEqual(metres, 11_119, accuracy: 50)
    }

    func testTheQueueIsBounded() {
        // A phone away from its PC for a month should not be holding a month of positions to send
        // in one burst.
        var queue: [Whereabouts] = []

        for minute in 0..<(WhereaboutsRules.queueLimit + 50) {
            queue = WhereaboutsRules.queue(queue, adding: at(Double(minute)))
        }

        XCTAssertEqual(queue.count, WhereaboutsRules.queueLimit)
    }

    func testAndItIsTheOldestThatGoes() {
        var queue: [Whereabouts] = []

        for minute in 0..<(WhereaboutsRules.queueLimit + 1) {
            queue = WhereaboutsRules.queue(queue, adding: at(Double(minute)))
        }

        // The first minute is gone and the last is still there: what is kept is the recent history,
        // which is the half anybody asks about.
        XCTAssertEqual(queue.first?.at, at(1).at)
        XCTAssertEqual(queue.last?.at, at(Double(WhereaboutsRules.queueLimit)).at)
    }

    func testAReadingSurvivesBeingWrittenAndReadBack() throws {
        // The queue outlives the app being closed, which is the whole point of it.
        let reading = at(0)
        let data = try JSONEncoder().encode([reading])
        let read = try JSONDecoder().decode([Whereabouts].self, from: data)

        XCTAssertEqual(read, [reading])
    }

    func testWhatIsSentNamesTheFieldsThePcReads() {
        // The PC refuses a reading without latitude and longitude, and reads `at` for when the
        // device took it rather than when it arrived.
        let body = at(0).body

        XCTAssertNotNil(body["latitude"] as? Double)
        XCTAssertNotNil(body["longitude"] as? Double)
        XCTAssertNotNil(body["accuracy"] as? Double)
        XCTAssertNotNil(body["at"] as? String)
    }
}
