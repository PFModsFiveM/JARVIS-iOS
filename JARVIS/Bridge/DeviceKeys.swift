import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A P-256 signing key whose private half this app never sees.
protocol BridgeSigningKey {
    var publicKeyX963: Data { get }
    func sign(_ data: Data) throws -> Data
}

/// The phone's two keys, made once and kept in the Secure Enclave:
///
/// - **identity** proves to the PC which paired phone is connecting. Usable whenever the phone has been unlocked
///   once since starting, so the app can reconnect in the background.
/// - **approval** signs the requests that could stop the Security Protocol protecting the PC (standing it down,
///   answering a challenge). The Secure Enclave only uses it after Face ID, and forgets it if Face ID enrolment
///   changes - so a new face added to the phone cannot approve anything.
///
/// Only the Secure Enclave's opaque, device-bound handles are stored in the Keychain; they are useless on any other
/// device. On the Simulator, which has no Secure Enclave, software keys stand in so the UI can be tried.
enum DeviceKeys {
    enum Failure: LocalizedError {
        case accessControl
        case cancelled

        var errorDescription: String? {
            switch self {
            case .accessControl: return "The Secure Enclave key could not be created."
            case .cancelled: return "Face ID was cancelled."
            }
        }
    }

    private static let identityAccount = "identity-key"
    private static let approvalAccount = "approval-key"

    static func identity() throws -> BridgeSigningKey {
        if SecureEnclave.isAvailable {
            if let blob = Keychain.read(identityAccount) {
                return EnclaveKey(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
            }
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], nil) else {
                throw Failure.accessControl
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            Keychain.write(identityAccount, key.dataRepresentation)
            return EnclaveKey(key: key)
        }

        return try SoftwareKey.load(account: identityAccount)
    }

    /// The approval key's public half, for pairing. Making it does not need Face ID; using it does.
    static func approvalPublicKey() throws -> Data {
        if SecureEnclave.isAvailable {
            if let blob = Keychain.read(approvalAccount) {
                let context = LAContext()
                context.interactionNotAllowed = true   // reading the public key must never prompt
                return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context).publicKey.x963Representation
            }
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil) else {
                throw Failure.accessControl
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            Keychain.write(approvalAccount, key.dataRepresentation)
            return key.publicKey.x963Representation
        }

        return try SoftwareKey.load(account: approvalAccount).publicKeyX963
    }

    /// Signs with the approval key after Face ID, with `reason` shown in the Face ID sheet.
    static func approve(_ data: Data, reason: String) async throws -> Data {
        if SecureEnclave.isAvailable {
            guard let blob = Keychain.read(approvalAccount) else { throw Failure.accessControl }
            let context = LAContext()
            do {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            } catch {
                throw Failure.cancelled
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            return try key.signature(for: data).derRepresentation
        }

        return try SoftwareKey.load(account: approvalAccount).sign(data)
    }

    /// Forgetting the PC also throws away both keys: pairing again makes new ones.
    static func erase() {
        Keychain.delete(identityAccount)
        Keychain.delete(approvalAccount)
    }
}

private struct EnclaveKey: BridgeSigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
}

/// Simulator only.
private struct SoftwareKey: BridgeSigningKey {
    let key: P256.Signing.PrivateKey
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }

    static func load(account: String) throws -> SoftwareKey {
        if let raw = Keychain.read(account) {
            return SoftwareKey(key: try P256.Signing.PrivateKey(rawRepresentation: raw))
        }
        let key = P256.Signing.PrivateKey()
        Keychain.write(account, key.rawRepresentation)
        return SoftwareKey(key: key)
    }
}

/// Generic-password items for this app, never synced to iCloud and never restored to another device.
enum Keychain {
    private static let service = "uk.jarvis.bridge"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func write(_ account: String, _ data: Data) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
