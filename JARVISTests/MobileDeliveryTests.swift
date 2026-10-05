import XCTest
@testable import JARVIS

/// Whether this phone may say something - priority §1D.
///
/// The owner-facing failure: they ask the phone to open Blender, put it in a pocket, the PC opens
/// it and says so out loud, and the phone comes back. Without this the phone has a turn it
/// believes it owns and an answer it has never given, so it gives it - and one thing is announced
/// twice by two devices, which is the most obviously broken behaviour an assistant with two bodies
/// can have.
@MainActor
final class MobileDeliveryTests: XCTestCase {
    private var folder: URL!
    private var store: URL!

    override func setUp() {
        super.setUp()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-delivery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = folder.appendingPathComponent("delivery.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func book() -> MobileDelivery { MobileDelivery(store: store) }

    private func row(
        _ id: String,
        _ state: MobileDeliveryState,
        by: String? = nil,
        revision: Int64 = 1,
        because: String = ""
    ) -> MobileResult {
        MobileResult(
            id: id, turn: "turn-1", conversation: "conv", task: nil,
            state: state, by: by, revision: revision, because: because)
    }

    // MARK: - the question

    func testNobodyHavingSaidItMeansThisPhoneMay() {
        let held = book()
        held.apply([row("r1", .ready)], through: 1)

        XCTAssertEqual(held.maySay("r1", node: "iPhone"), .yes)
        XCTAssertTrue(held.maySay("r1", node: "iPhone").speak)
    }

    func testAnotherDeviceHavingSaidItMeansThisPhoneMayNot() {
        let held = book()
        held.apply([row("r1", .delivered, by: "PC-PRIME")], through: 1)

        let verdict = held.maySay("r1", node: "iPhone")

        XCTAssertFalse(verdict.speak)
        XCTAssertTrue(verdict.because.contains("PC-PRIME"))
    }

    func testThisPhoneHavingSaidItMeansItDoesNotSayItAgain() {
        let held = book()
        held.apply([row("r1", .ready)], through: 1)
        held.said("r1")

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testSomethingThatMayHaveBeenDeliveredIsNotRepeated() {
        let held = book()
        held.apply([row("r1", .deliveryUnknown, because: "nothing acknowledged it")], through: 1)

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testSomethingTooOldToSayIsNotSaid() {
        let held = book()
        held.apply([row("r1", .expired, because: "too old to be worth saying")], through: 1)

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testSomethingAnotherDeviceIsSayingIsNotSaidToo() {
        let held = book()
        held.apply([row("r1", .deliveryPending)], through: 1)

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testWorkThatIsStillGoingHasNothingToSayYet() {
        let held = book()
        held.apply([row("r1", .notReady)], through: 1)

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testWithNoRecordAndNoMemoryThePhoneSaysItAnyway() {
        let held = book()

        let verdict = held.maySay("r1", node: "iPhone")

        // The deliberate choice. An owner who asked a question and got silence is worse served
        // than one who hears something twice, and the PC's ledger records the duplicate so it can
        // be measured rather than guessed at.
        guard case .unknown = verdict else {
            return XCTFail("a result nobody has mentioned should be unknown, not refused")
        }

        XCTAssertTrue(verdict.speak)
    }

    func testAPhoneThatSpokeOfflineDoesNotRepeatItselfEvenWithNoRecord() {
        let held = book()
        held.said("r1")

        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    // MARK: - catching up

    func testAReplayedBatchChangesNothing() {
        let held = book()
        held.apply([row("r1", .delivered, by: "PC-PRIME", revision: 4)], through: 4)
        held.apply([row("r1", .ready, revision: 2)], through: 4)

        // A row with a revision no higher than the one held is a replay, and applying it would
        // undo a newer state this phone was already told about.
        XCTAssertEqual(held.results.first?.state, .delivered)
        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    func testTheCursorOnlyGoesForward() {
        let held = book()
        held.apply([row("r1", .ready, revision: 9)], through: 9)
        held.apply([], through: 2)

        XCTAssertEqual(held.revision, 9)
    }

    func testWhatThisPhoneSaidIsWhatItReports() {
        let held = book()
        held.apply([row("r1", .ready), row("r2", .ready, revision: 2)], through: 2)
        held.said("r1")

        XCTAssertEqual(held.unreported(), ["r1"])
    }

    func testAReportThePcAcceptedIsNotSentAgain() {
        let held = book()
        held.apply([row("r1", .ready)], through: 1)
        held.said("r1")
        held.reported("r1", by: "iPhone")

        XCTAssertTrue(held.unreported().isEmpty)
        XCTAssertEqual(held.results.first?.state, .delivered)
    }

    func testFailingToCatchUpKeepsWhatIsAlreadyKnown() {
        let held = book()
        held.apply([row("r1", .delivered, by: "PC-PRIME")], through: 1)
        held.couldNotCatchUp("the PC isn't answering")

        XCTAssertEqual(held.failed, "the PC isn't answering")
        XCTAssertFalse(held.maySay("r1", node: "iPhone").speak)
    }

    // MARK: - across a restart

    func testWhatWasDeliveredSurvivesTheAppBeingKilled() {
        let first = book()
        first.apply([row("r1", .delivered, by: "PC-PRIME")], through: 3)

        let again = MobileDelivery(store: store)

        XCTAssertEqual(again.revision, 3)
        XCTAssertFalse(again.maySay("r1", node: "iPhone").speak)
    }

    func testWhatThisPhoneSaidSurvivesTheAppBeingKilled() {
        let first = book()
        first.said("r1")

        let again = MobileDelivery(store: store)

        // The case this is on disk for: the phone spoke, was killed, and must not speak again.
        XCTAssertFalse(again.maySay("r1", node: "iPhone").speak)
    }

    func testForgettingEverythingLeavesNothingBehind() {
        let held = book()
        held.apply([row("r1", .delivered, by: "PC-PRIME")], through: 3)
        held.said("r2")
        held.forget()

        XCTAssertTrue(held.results.isEmpty)
        XCTAssertTrue(held.spoken.isEmpty)
        XCTAssertEqual(held.revision, 0)
    }

    func testTheStoreIsBounded() {
        let held = book()

        let rows = (0..<(MobileDelivery.keep + 50)).map {
            row("r\($0)", .delivered, by: "PC-PRIME", revision: Int64($0 + 1))
        }

        held.apply(rows, through: Int64(rows.count))

        XCTAssertLessThanOrEqual(held.results.count, MobileDelivery.keep)
    }

    func testTheStatesAreNamedTheSameAsThePcs() {
        // One mechanism with two halves. A phone that called the states something else would be a
        // phone whose logs could not be read against the PC's.
        XCTAssertEqual(MobileDeliveryState.delivered.rawValue, "Delivered")
        XCTAssertEqual(MobileDeliveryState.deliveryUnknown.rawValue, "DeliveryUnknown")
        XCTAssertEqual(MobileDeliveryState.deliveryPending.rawValue, "DeliveryPending")
        XCTAssertEqual(MobileDeliveryState.notReady.rawValue, "NotReady")
        XCTAssertEqual(MobileDeliveryState.expired.rawValue, "Expired")
        XCTAssertEqual(MobileDeliveryState.ready.rawValue, "Ready")
    }

    func testOnlyReadyIsSayable() {
        for state in [MobileDeliveryState.notReady, .deliveryPending, .delivered, .deliveryUnknown, .expired] {
            XCTAssertFalse(state.sayable, "\(state) should not be sayable")
        }

        XCTAssertTrue(MobileDeliveryState.ready.sayable)
    }

    func testSentinel() { XCTAssertTrue(true) }
}
