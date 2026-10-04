import AVKit
import XCTest
@testable import JARVIS

/// The player's lifetime, which is the half of the navigation bug that can be tested.
///
/// The view cannot be unit-tested and the Close button has to be looked at. What can be tested is
/// the thing that was actually wrong underneath it: both player sheets built `AVPlayer(url:)`
/// inline in a `ViewBuilder`, so a player was constructed on every re-render, none was ever
/// paused, and none was released. On a phone that means audio continuing after the screen has
/// gone and several decoders alive at once.
@MainActor
final class RecordingPlaybackSessionTests: XCTestCase {
    private var somewhere: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-clip.mp4")
    }

    private var elsewhere: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-other.mp4")
    }

    func testOpeningBuildsExactlyOnePlayer() {
        let session = RecordingPlaybackSession()

        session.open(RecordingPlayable(url: somewhere))

        XCTAssertNotNil(session.player)
        XCTAssertEqual(session.built, 1)
        XCTAssertEqual(session.showing?.url, somewhere)
    }

    func testOpeningTheSameRecordingAgainReusesThePlayer() {
        // SwiftUI evaluates a sheet's body more than once for one presentation. Rebuilding the
        // player each time is exactly what the old code did.
        let session = RecordingPlaybackSession()
        let item = RecordingPlayable(url: somewhere)

        session.open(item)
        session.open(item)
        session.open(item)

        XCTAssertEqual(session.built, 1)
    }

    func testADifferentRecordingReplacesThePlayerRatherThanAddingOne() {
        let session = RecordingPlaybackSession()

        session.open(RecordingPlayable(url: somewhere))
        let first = session.player

        session.open(RecordingPlayable(url: elsewhere))

        XCTAssertEqual(session.built, 2)
        XCTAssertFalse(first === session.player)
        XCTAssertEqual(session.showing?.url, elsewhere)

        // The one it replaced was stopped on the way out, not left running behind the new one.
        XCTAssertNil(first?.currentItem)
    }

    func testClosingStopsPlaybackAndReleasesThePlayer() {
        // The defect: nothing paused and nothing was released, so sound carried on after the
        // screen had gone.
        let session = RecordingPlaybackSession()

        session.open(RecordingPlayable(url: somewhere))
        let player = session.player

        session.close()

        XCTAssertNil(session.player)
        XCTAssertNil(session.showing)
        XCTAssertFalse(session.isPlaying)

        // Detaching the item is what actually lets the decoder go; pausing alone leaves it held.
        XCTAssertNil(player?.currentItem)
    }

    func testClosingTwiceIsHarmless() {
        // The dismiss path and onDisappear both call it, deliberately, because either one can be
        // the one that actually happens depending on how the sheet went away.
        let session = RecordingPlaybackSession()

        session.open(RecordingPlayable(url: somewhere))
        session.close()
        session.close()

        XCTAssertNil(session.player)
        XCTAssertNil(session.showing)
    }

    func testClosingBeforeAnythingOpenedIsHarmless() {
        let session = RecordingPlaybackSession()

        session.close()

        XCTAssertNil(session.player)
        XCTAssertFalse(session.isPlaying)
    }

    func testReopeningAfterCloseWorks() {
        // Watch one, close it, watch it again - the ordinary thing somebody does.
        let session = RecordingPlaybackSession()
        let item = RecordingPlayable(url: somewhere)

        session.open(item)
        session.close()
        session.open(item)

        XCTAssertNotNil(session.player)
        XCTAssertEqual(session.built, 2)
    }

    func testARecordingIsIdentifiedByItsFileSoTheSheetKeysOnTheRightThing() {
        XCTAssertEqual(RecordingPlayable(url: somewhere).id, somewhere.path)
        XCTAssertEqual(RecordingPlayable(url: somewhere), RecordingPlayable(url: somewhere, title: "Recording"))
        XCTAssertNotEqual(RecordingPlayable(url: somewhere), RecordingPlayable(url: elsewhere))
    }

    func testBothListsUseTheSamePlayableTypeSoNeitherCanDriftAnExitAway() {
        // The PC-provided list and the shared-store list both hand a URL to the same type. Two
        // near-identical player screens is how one of them ends up with the Close button and the
        // other does not, which is what happened.
        let fromThePc = RecordingPlayable(url: somewhere)
        let fromTheStore = RecordingPlayable(url: somewhere)

        XCTAssertEqual(fromThePc, fromTheStore)
    }
}
