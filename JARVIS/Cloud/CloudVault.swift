import CryptoKit
import Foundation

/// The key every device of this JARVIS seals store objects with, as this phone holds it.
///
/// The store is a company's disk. What goes on it is sealed first, so the store holds bytes it
/// cannot read - and that means this phone cannot read them either without the key. It comes from
/// the PC over the already-encrypted, device-pinned bridge, and only after Face ID, because it is
/// the one thing that makes everything in the store readable.
///
/// Kept in the Keychain, device-only and never synchronised. Never logged, never in a payload, and
/// `description` prints nothing.
struct CloudVault: CustomStringConvertible {
    /// AES-256: thirty-two bytes.
    static let keyBytes = 32

    /// What a sealed object begins with, so something that is not one is recognised rather than
    /// mangled. The PC writes the same three bytes.
    static let magic = Data("JV1".utf8)

    /// AES-GCM's nonce, random per object on the PC and read from in front of the ciphertext here.
    static let nonceBytes = 12

    /// AES-GCM's tag: what makes this authenticated rather than merely encrypted.
    static let tagBytes = 16

    let key: SymmetricKey

    var description: String { "CloudVault(***)" }

    /// Takes the key as the PC writes it down: Base64 of thirty-two bytes.
    ///
    /// Refuses anything that is not a key rather than storing rubbish that would fail later at the
    /// first read and look like a corrupt bucket.
    init?(written: String) {
        guard let bytes = Data(base64Encoded: written.trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes.count == Self.keyBytes
        else { return nil }

        key = SymmetricKey(data: bytes)
    }

    /// Opens what the PC sealed, or nil when it was not sealed by this key.
    ///
    /// Nil rather than throwing, because the ordinary reasons are ordinary: an object written by a
    /// JARVIS whose key this phone does not have, or a file in the bucket that is not one of ours.
    /// A tampered object lands here too and is indistinguishable, which is correct - the answer in
    /// both cases is to ignore it.
    func open(_ sealed: Data) -> Data? {
        let overhead = Self.magic.count + Self.nonceBytes + Self.tagBytes

        guard sealed.count >= overhead else { return nil }
        guard sealed.prefix(Self.magic.count) == Self.magic else { return nil }

        let body = sealed.dropFirst(Self.magic.count)
        let nonce = body.prefix(Self.nonceBytes)
        let rest = body.dropFirst(Self.nonceBytes)
        let ciphertext = rest.dropLast(Self.tagBytes)
        let tag = rest.suffix(Self.tagBytes)

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag)

            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------------ keeping it

    private static let account = "cloud-vault-key"

    static func load() -> CloudVault? {
        guard let data = Keychain.read(account) else { return nil }

        return CloudVault(written: data.base64EncodedString())
    }

    /// Stores the key. Refuses one that is not a key, and says so.
    @discardableResult
    static func remember(written: String) -> CloudVault? {
        guard let vault = CloudVault(written: written),
              let bytes = Data(base64Encoded: written.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        Keychain.write(account, bytes)

        return vault
    }

    static func forget() { Keychain.delete(account) }
}

/// Where the shared store is, as the PC told this phone.
///
/// Not secret - a bucket's name and host are in its own URL - but kept with the pairing rather than
/// in UserDefaults, because it only means anything alongside the key and the credential.
struct StoreCoordinates: Codable, Equatable {
    let host: String
    let bucket: String
    let region: String
    /// The PC's folder in the store, which is where its footage is.
    let device: String

    /// One `cloud.joined` reply, or nil for anything incomplete.
    init?(_ body: [String: Any]) {
        guard let host = body["host"] as? String, !host.isEmpty,
              let bucket = body["bucket"] as? String, !bucket.isEmpty,
              let device = body["device"] as? String, !device.isEmpty
        else { return nil }

        self.host = host
        self.bucket = bucket
        region = (body["region"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        self.device = device
    }

    private static let account = "store-coordinates"

    static func load() -> StoreCoordinates? {
        guard let data = Keychain.read(account) else { return nil }
        return try? JSONDecoder().decode(StoreCoordinates.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.write(Self.account, data) }
    }

    static func forget() { Keychain.delete(account) }
}
