import CryptoKit
import Foundation

/// The Mobile Bridge's cryptography, version 2 - the Swift twin of `BridgeCrypto.cs` on the PC.
///
/// Every function here must produce exactly the bytes the PC produces. `BridgeSelfTest` checks that against the
/// vectors the PC's unit test publishes in `docs/bridge-v2-vectors.json`.
///
/// Encodings: public keys X9.63 uncompressed (65 bytes), signatures DER, text UTF-8, integers big-endian.
enum BridgeCrypto {
    static let protocolVersion = 2
    static let nonceBytes = 32
    static let keyBytes = 32
    static let tagBytes = 16
    static let counterBytes = 8

    static let clientToServer: UInt32 = 1
    static let serverToClient: UInt32 = 2

    private static let label = Data("JARVIS-BRIDGE-v2".utf8)

    // MARK: transcript and key schedule

    /// SHA-256 over the label and every field, each prefixed with its 4-byte big-endian length.
    static func transcript(clientEphemeral: Data, clientNonce: Data, serverEphemeral: Data, serverNonce: Data,
                           serverStatic: Data, mode: String, deviceId: String) -> Data {
        var hash = SHA256()
        hash.update(data: label)
        for field in [clientEphemeral, clientNonce, serverEphemeral, serverNonce, serverStatic, Data(mode.utf8), Data(deviceId.utf8)] {
            hash.update(data: bigEndian(UInt32(field.count)))
            hash.update(data: field)
        }
        return Data(hash.finalize())
    }

    /// Client-to-server key, then server-to-client key.
    static func trafficKeys(sharedSecret: Data, transcript: Data) -> (clientToServer: Data, serverToClient: Data) {
        let keys = hkdf(sharedSecret, salt: transcript, info: "jarvis-bridge-v2 keys", count: 2 * keyBytes)
        return (Data(keys.prefix(keyBytes)), Data(keys.suffix(keyBytes)))
    }

    /// The six digits both screens show while pairing.
    static func shortAuthenticationString(sharedSecret: Data, transcript: Data) -> String {
        let bytes = hkdf(sharedSecret, salt: transcript, info: "jarvis-bridge-v2 sas", count: 4)
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// What a signature of a purpose is over: SHA-256(purpose || 0 || transcript || 0 || detail).
    static func signed(_ purpose: String, transcript: Data, detail: String = "") -> Data {
        var hash = SHA256()
        hash.update(data: Data(purpose.utf8))
        hash.update(data: Data([0]))
        hash.update(data: transcript)
        hash.update(data: Data([0]))
        hash.update(data: Data(detail.utf8))
        return Data(hash.finalize())
    }

    static func verify(publicKeyX963: Data, data: Data, derSignature: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: derSignature) else { return false }
        // CryptoKit hashes `data` with SHA-256, as .NET's VerifyData does.
        return key.isValidSignature(signature, for: data)
    }

    // MARK: frames

    /// counter (8) || ciphertext || tag (16). Nonce = direction (4) || counter (8); associated data = transcript.
    static func seal(key: Data, direction: UInt32, counter: UInt64, plaintext: Data, transcript: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: bigEndian(direction) + bigEndian(counter))
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: transcript)
        return bigEndian(counter) + box.ciphertext + box.tag
    }

    /// Nil when the frame was edited, is for the other direction, or is not the next one expected.
    static func open(key: Data, direction: UInt32, expectedCounter: UInt64, frame: Data, transcript: Data) -> Data? {
        guard frame.count >= counterBytes + tagBytes else { return nil }
        let bytes = [UInt8](frame)
        let counter = bytes.prefix(counterBytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter == expectedCounter else { return nil }

        do {
            let nonce = try AES.GCM.Nonce(data: bigEndian(direction) + bigEndian(counter))
            let box = try AES.GCM.SealedBox(nonce: nonce,
                                            ciphertext: Data(bytes[counterBytes..<(bytes.count - tagBytes)]),
                                            tag: Data(bytes[(bytes.count - tagBytes)...]))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: transcript)
        } catch {
            return nil
        }
    }

    // MARK: helpers

    static func hkdf(_ secret: Data, salt: Data, info: String, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                         info: Data(info.utf8), outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func bigEndian(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}

extension Data {
    init?(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

/// Checks this phone's CryptoKit against the values the PC computed (docs/bridge-v2-vectors.json in the JARVIS repo).
/// If any line fails, the app would never talk to the PC, so Settings shows the result.
enum BridgeSelfTest {
    static func run() -> [(name: String, passed: Bool)] {
        let secret = Data(hex: "8B1F2E3D4C5B6A79887766554433221100FFEEDDCCBBAA99887766554433AA01")!
        let transcript = BridgeCrypto.transcript(
            clientEphemeral: Data(repeating: 1, count: 65), clientNonce: Data(repeating: 2, count: 32),
            serverEphemeral: Data(repeating: 3, count: 65), serverNonce: Data(repeating: 4, count: 32),
            serverStatic: Data(repeating: 5, count: 65), mode: "resume", deviceId: "device-1")
        let keys = BridgeCrypto.trafficKeys(sharedSecret: secret, transcript: transcript)
        let frame = try? BridgeCrypto.seal(key: keys.clientToServer, direction: BridgeCrypto.clientToServer, counter: 7,
                                           plaintext: Data("{\"kind\":\"ping\"}".utf8), transcript: transcript)

        return [
            ("transcript", transcript.hex == "B9355464B7EF3AE7B201C4BB94E703F37D28C2E07D933C8EBCC87504551DFCDE"),
            ("client-to-server key", keys.clientToServer.hex == "6C464E793A93CAE78A82876BCC26ED9571F462ABA4D3F9F1B6DE5F885F544D75"),
            ("server-to-client key", keys.serverToClient.hex == "7181565AB5D64C37B09F11F9AAEB4051F4F12E6416C76DC7B59AB98E6EF0E3E7"),
            ("six digits", BridgeCrypto.shortAuthenticationString(sharedSecret: secret, transcript: transcript) == "244048"),
            ("approval data", BridgeCrypto.signed("approve", transcript: transcript, detail: "security.standDown\nabc").hex
                == "B5B75987C4A4C5E92E2F5FE0E29195FB924BC9AE7E0057067918202754EB1591"),
            ("frame", frame?.hex == "0000000000000007C9873EFB96AC0632D8A096AB814654C8E48CC87EC3B8044C28E7BD460F1E3D"),
            ("frame opens", frame.flatMap { BridgeCrypto.open(key: keys.clientToServer, direction: BridgeCrypto.clientToServer,
                                                             expectedCounter: 7, frame: $0, transcript: transcript) }
                == Data("{\"kind\":\"ping\"}".utf8)),
            ("wrong direction refused", frame.flatMap { BridgeCrypto.open(key: keys.clientToServer, direction: BridgeCrypto.serverToClient,
                                                                         expectedCounter: 7, frame: $0, transcript: transcript) } == nil)
        ]
    }
}
