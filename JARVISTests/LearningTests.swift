import XCTest
@testable import JARVIS

/// The phone's side of the learning session: reading the PC's `BridgeLearning` exactly as it is
/// written - camelCase names - so a change on either side that breaks the other fails here.
final class LearningTests: XCTestCase {
    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "running": true,
            "state": "running",
            "phase": "reflecting on what went wrong",
            "step": 2,
            "steps": 5,
            "done": 140,
            "of": 812,
            "origin": "phone",
            "startedAt": "2026-09-26T12:00:00.1234567+00:00",
            "said": "Learning session running (started from phone): step 2 of 5, reflecting on what went wrong - 140 of 812."
        ]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    func testARunningSessionIsReadWithItsCounts() {
        let status = LearningStatus(row())!

        XCTAssertTrue(status.running)
        XCTAssertEqual(status.step, 2)
        XCTAssertEqual(status.steps, 5)
        XCTAssertEqual(status.done, 140)
        XCTAssertEqual(status.of, 812)
        XCTAssertEqual(status.origin, "phone")
        XCTAssertEqual(status.stepFraction!, 140.0 / 812.0, accuracy: 0.0001)
    }

    func testAStepWithoutItemsHasNoBar() {
        XCTAssertNil(LearningStatus(row(["done": 0, "of": 0]))!.stepFraction)
    }

    func testARowWithoutAStateIsNotASession() {
        var broken = row()
        broken.removeValue(forKey: "state")
        XCTAssertNil(LearningStatus(broken))
        XCTAssertNil(LearningStatus(nil))
    }

    @MainActor
    func testAPushMovesTheCard() {
        let learning = LearningModel()
        learning.receive(BridgeMessage(kind: "learning.changed", id: "", body: ["session": row(["step": 4, "phase": "testing proposed improvements"])]))

        XCTAssertEqual(learning.status.step, 4)
        XCTAssertEqual(learning.status.phase, "testing proposed improvements")
    }
}
