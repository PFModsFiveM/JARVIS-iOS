import CryptoKit
import XCTest
@testable import JARVIS

/// The one thing that must be right before anything else can work: this iPhone computes the same bytes as the PC.
/// The expected values come from the PC's own unit test (`docs/bridge-v2-vectors.json` in the JARVIS repository).
final class BridgeCryptoTests: XCTestCase {
    func testTheKeyScheduleMatchesThePC() {
        for check in BridgeSelfTest.run() {
            XCTAssertTrue(check.passed, "\(check.name) does not match the PC")
        }
    }

    func testAFrameOpensOnlyUnchangedInTheRightDirectionAndOrder() throws {
        let key = Data(repeating: 9, count: 32)
        let transcript = Data(repeating: 7, count: 32)
        let plaintext = Data("{\"kind\":\"status\"}".utf8)
        let frame = try BridgeCrypto.seal(key: key, direction: BridgeCrypto.clientToServer, counter: 3,
                                          plaintext: plaintext, transcript: transcript)

        XCTAssertEqual(BridgeCrypto.open(key: key, direction: BridgeCrypto.clientToServer, expectedCounter: 3,
                                         frame: frame, transcript: transcript), plaintext)

        var edited = frame
        edited[edited.count - 20] ^= 1
        XCTAssertNil(BridgeCrypto.open(key: key, direction: BridgeCrypto.clientToServer, expectedCounter: 3,
                                       frame: edited, transcript: transcript), "an edited frame must not open")
        XCTAssertNil(BridgeCrypto.open(key: key, direction: BridgeCrypto.clientToServer, expectedCounter: 4,
                                       frame: frame, transcript: transcript), "a repeated counter must not open")
        XCTAssertNil(BridgeCrypto.open(key: key, direction: BridgeCrypto.serverToClient, expectedCounter: 3,
                                       frame: frame, transcript: transcript), "the other direction must not open")
        XCTAssertNil(BridgeCrypto.open(key: key, direction: BridgeCrypto.clientToServer, expectedCounter: 3,
                                       frame: frame, transcript: Data(repeating: 8, count: 32)),
                     "another session's transcript must not open")
    }

    func testTheTranscriptBindsEveryField() {
        let base = BridgeCrypto.transcript(clientEphemeral: Data(repeating: 1, count: 65), clientNonce: Data(repeating: 2, count: 32),
                                           serverEphemeral: Data(repeating: 3, count: 65), serverNonce: Data(repeating: 4, count: 32),
                                           serverStatic: Data(repeating: 5, count: 65), mode: "resume", deviceId: "device-1")
        let otherMode = BridgeCrypto.transcript(clientEphemeral: Data(repeating: 1, count: 65), clientNonce: Data(repeating: 2, count: 32),
                                                serverEphemeral: Data(repeating: 3, count: 65), serverNonce: Data(repeating: 4, count: 32),
                                                serverStatic: Data(repeating: 5, count: 65), mode: "pair", deviceId: "device-1")
        let otherDevice = BridgeCrypto.transcript(clientEphemeral: Data(repeating: 1, count: 65), clientNonce: Data(repeating: 2, count: 32),
                                                  serverEphemeral: Data(repeating: 3, count: 65), serverNonce: Data(repeating: 4, count: 32),
                                                  serverStatic: Data(repeating: 5, count: 65), mode: "resume", deviceId: "device-2")
        XCTAssertNotEqual(base, otherMode)
        XCTAssertNotEqual(base, otherDevice)
    }

    func testASignatureIsVerifiedOnlyForItsOwnPurposeAndDetail() throws {
        let key = P256.Signing.PrivateKey()
        let transcript = Data(repeating: 6, count: 32)
        let data = BridgeCrypto.signed("approve", transcript: transcript, detail: "security.standDown\nabc")
        let signature = try key.signature(for: data).derRepresentation

        XCTAssertTrue(BridgeCrypto.verify(publicKeyX963: key.publicKey.x963Representation, data: data, derSignature: signature))
        XCTAssertFalse(BridgeCrypto.verify(publicKeyX963: key.publicKey.x963Representation,
                                           data: BridgeCrypto.signed("approve", transcript: transcript, detail: "security.standDown\nxyz"),
                                           derSignature: signature), "an approval must not count for another request")
        XCTAssertFalse(BridgeCrypto.verify(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation,
                                           data: data, derSignature: signature), "another key must not verify")
    }

    func testHexRoundTrip() {
        let data = Data([0x00, 0x0F, 0xA5, 0xFF])
        XCTAssertEqual(data.hex, "000FA5FF")
        XCTAssertEqual(Data(hex: "000FA5FF"), data)
    }
}
