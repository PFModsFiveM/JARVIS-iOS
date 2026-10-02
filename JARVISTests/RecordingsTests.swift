import XCTest
@testable import JARVIS

/// What the camera kept, as the phone groups it.
///
/// The rows here are the PC's `camera.recordings` reply field for field, so a change on either
/// side that breaks the other fails here rather than on the owner's phone.
@MainActor
final class RecordingsTests: XCTestCase {
    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "id": "event-1",
            "at": ISO8601DateFormatter().string(from: Date()),
            "seconds": 12,
            "what": "Someone I don't know at the desk",
            "snapshots": 3,
            "acknowledged": false,
            "clips": [
                ["kind": "Evidence", "name": "evidence.mp4", "bytes": 4_000_000],
                ["kind": "Camera", "name": "camera.mp4", "bytes": 2_000_000]
            ]
        ]

        overrides.forEach { row[$0.key] = $0.value }

        return row
    }

    private func recording(_ overrides: [String: Any] = [:]) -> SecurityRecording {
        let made = RecordingsModel.read(row(overrides))
        XCTAssertNotNil(made, "the row should have read")

        return made!
    }

    func testSeenIsReadFromThePC() {
        // The store has carried Acknowledged since security events existed and the recordings
        // list never sent it, so the phone could show a week of incidents without knowing which
        // were new - and the hide action had nothing on screen able to show it had worked.
        XCTAssertFalse(recording().seen)
        XCTAssertTrue(recording(["acknowledged": true]).seen)
    }

    func testAnOlderPCThatDoesNotSendItIsTreatedAsUnseen() {
        // Unseen is the safe default: an incident shown that did not need to be is a glance, and
        // one hidden that should not have been is a recording nobody watches.
        var without = row()
        without.removeValue(forKey: "acknowledged")

        XCTAssertEqual(RecordingsModel.read(without)?.seen, false)
    }

    func testRecentIsTheLastDay() {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))

        XCTAssertTrue(recording().isRecent)
        XCTAssertFalse(recording(["at": old]).isRecent)
    }

    func testTheThreeSectionsDoNotOverlap() {
        // Every incident belongs to exactly one of them, whatever its age or state. A recording
        // in two sections is a recording somebody watches twice; one in none is a recording
        // nobody sees at all.
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))

        let model = RecordingsModel()
        model.accept([
            row(["id": "a"]),
            row(["id": "b", "at": old]),
            row(["id": "c", "acknowledged": true]),
            row(["id": "d", "at": old, "acknowledged": true])
        ])

        XCTAssertEqual(model.recent.map(\.id), ["a"])
        XCTAssertEqual(model.earlier.map(\.id), ["b"])
        XCTAssertEqual(Set(model.hidden.map(\.id)), ["c", "d"])

        let counted = model.recent.count + model.earlier.count + model.hidden.count
        XCTAssertEqual(counted, 4, "every incident should be in exactly one section")
    }

    func testHidingIsReversible() {
        // Hidden is not deleted. The one time this matters is the time somebody taps it by
        // mistake on the only recording of a stranger at their desk.
        let model = RecordingsModel()
        model.accept([row(["id": "a", "acknowledged": true])])

        XCTAssertEqual(model.hidden.map(\.id), ["a"])
        XCTAssertTrue(model.recent.isEmpty)

        model.accept([row(["id": "a", "acknowledged": false])])

        XCTAssertEqual(model.recent.map(\.id), ["a"])
        XCTAssertTrue(model.hidden.isEmpty)
    }
}
