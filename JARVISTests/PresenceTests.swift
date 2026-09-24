import AVFoundation
import XCTest
@testable import JARVIS

/// What the phone tells the PC about itself, and the one word in it that is easy to get wrong.
///
/// The PC weighs "worn" at 0.65 and describes it as "on the user, and heard by nobody else" - it is
/// about private audio, not about being held. A phone reporting itself worn because somebody has it
/// in their hand would send private answers to a loudspeaker on a table, which is the opposite of
/// what the word is weighed for. The honest reading for a phone is where its audio is going.
final class PresenceTests: XCTestCase {
    func testHeadphonesAreHeardByNobodyElse() {
        XCTAssertTrue(AppModel.privateAudio([.headphones]))
        XCTAssertTrue(AppModel.privateAudio([.bluetoothA2DP]))
        XCTAssertTrue(AppModel.privateAudio([.bluetoothHFP]))
    }

    func testTheEarpieceIs() {
        // Held to the ear during a call: as private as audio gets.
        XCTAssertTrue(AppModel.privateAudio([.builtInReceiver]))
    }

    func testTheLoudspeakerIsNot() {
        // The case this exists to get right. A phone on a desk playing out loud is no more private
        // than the PC's own speakers, and claiming otherwise would take answers away from the PC
        // and say them into the room anyway.
        XCTAssertFalse(AppModel.privateAudio([.builtInSpeaker]))
    }

    func testNorIsSomethingAcrossTheRoom() {
        // AirPlay to a television, or a car. Both are somewhere else entirely and both are heard by
        // whoever is there.
        XCTAssertFalse(AppModel.privateAudio([.airPlay]))
        XCTAssertFalse(AppModel.privateAudio([.carAudio]))
    }

    func testNoOutputAtAllIsNotPrivate() {
        // Absence of evidence. The PC's own reading of a device that claims nothing is "claims
        // nothing", and that is the right answer here too.
        XCTAssertFalse(AppModel.privateAudio([]))
    }

    func testOnePrivateOutputIsEnough() {
        // Mirroring to a television while wearing headphones: what the owner hears is still private
        // to them, and the arbiter's question is about the owner.
        XCTAssertTrue(AppModel.privateAudio([.airPlay, .headphones]))
    }

    func testTheHeartbeatIsFasterThanThePcForgets() {
        // The PC forgets a device silent for ninety seconds, which is what lets the phone stay
        // honest by saying nothing when it stops knowing. It also means a phone still in use must
        // repeat itself before then, or it would go quiet while somebody was holding it.
        XCTAssertLessThan(AppModel.presenceEvery, 90)
    }
}
