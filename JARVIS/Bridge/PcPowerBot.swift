import CryptoKit
import Foundation
import Security

/// The Bot on this PC's power button, pressed by the phone when the PC cannot be asked.
///
/// Everywhere else in this app the phone holds no vendor credential: it asks the PC, and the PC's
/// Device Service talks to SwitchBot. That is a real property and it is kept everywhere it can be.
/// This is the one request where it cannot be: "switch the PC on" sent to a PC that is off has
/// nowhere to go, and a magic packet cannot leave a phone on mobile data.
///
/// So the PC hands these over - once, over the paired encrypted bridge, after Face ID - and they
/// live in the Keychain of this device only. They are used for one device id and one command, and
/// nothing here ever prints or logs them.
///
/// Turning the setting off on the PC stops further handovers; it does not reach into the phone.
/// `forget()` does that, and regenerating the token in the SwitchBot app is the only thing that
/// actually revokes anything.
enum PcPowerBot {
    /// What the PC handed over: the credentials, and the one device they may be used for.
    struct Handover: Codable, Equatable {
        let token: String
        let secret: String
        let deviceId: String
        let name: String

        /// A Bot in Press mode cannot be told "on"; the press is the same either way.
        let preferPress: Bool
    }

    enum Trouble: LocalizedError {
        case notSetUp
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp:
                return "This phone hasn't been given the power button yet. Open Settings on your PC while it's on."
            case .refused(let why):
                return why
            }
        }
    }

    // ------------------------------------------------------------------ the Keychain

    private static let service = "com.pfmods.jarvis.pcpower"
    private static let account = "switchbot"

    /// Whether this phone can press the button at all. Says nothing about what it holds.
    static var isSetUp: Bool { stored() != nil }

    /// The name to show, so a button can say what it presses rather than "the Bot".
    static var buttonName: String? { stored()?.name }

    static func remember(_ handover: Handover) throws {
        let data = try JSONEncoder().encode(handover)

        // This device only, and only while unlocked. Not synchronizable: a credential that rode
        // iCloud Keychain to an iPad would be a credential on a device nobody decided to trust.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(insert as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw Trouble.refused("The phone couldn't store that securely (\(status)).")
        }
    }

    /// Removes them from this phone. Does not revoke them - only SwitchBot can do that.
    static func forget() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    static func stored() -> Handover? {
        var item: CFTypeRef?

        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else { return nil }

        return try? JSONDecoder().decode(Handover.self, from: data)
    }

    /// Asks the PC to hand the button over. Face ID, every time, at the PC's insistence.
    ///
    /// Only possible while the PC is reachable, which is the whole arrangement: it is set up on a
    /// day the PC is on, so that it works on a day the PC is off.
    @discardableResult
    static func fetch(from client: BridgeClient) async throws -> Handover {
        let reply = try await client.approvedRequest(
            "devices.wake.handover",
            reason: "Let this phone switch your PC on")

        guard reply.kind == "devices.wake.handover",
              let token = reply.text("token"),
              let secret = reply.text("secret"),
              let button = reply.object("button"),
              let deviceId = button["deviceId"] as? String
        else {
            throw Trouble.refused(reply.message.isEmpty ? "Your PC wouldn't hand that over." : reply.message)
        }

        let handover = Handover(
            token: token,
            secret: secret,
            deviceId: deviceId,
            name: button["name"] as? String ?? "the power button",
            preferPress: button["preferPress"] as? Bool ?? false)

        try remember(handover)

        return handover
    }

    // ------------------------------------------------------------------ signing

    /// SwitchBot OpenAPI v1.1 request signing, as the vendor documents it.
    ///
    /// The string to sign is the token, the timestamp in milliseconds and the nonce, concatenated
    /// with nothing between them, signed with HMAC-SHA256 keyed by the secret, Base64-encoded and
    /// upper-cased.
    ///
    /// A pure function of its inputs so a test can hold it to a value worked out independently of
    /// this code. The PC's `SwitchBotAuth.Sign` is held to the same one: two implementations of a
    /// signature that agree only with themselves are two bugs waiting to meet.
    static func sign(token: String, secret: String, milliseconds: Int64, nonce: String) -> String {
        let message = Data((token + String(milliseconds) + nonce).utf8)
        let key = SymmetricKey(data: Data(secret.utf8))

        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).base64EncodedString().uppercased()
    }

    // ------------------------------------------------------------------ pressing it

    /// Presses the power button. Returns what to tell the owner.
    ///
    /// Deliberately says nothing about whether the PC then came up: that is the wake loop's
    /// question, answered by the bridge answering. All this knows is whether SwitchBot accepted
    /// the press, and claiming more would be the same fault as a light that says it is on because
    /// the command was accepted.
    @discardableResult
    static func press(now: Date = .now, nonce: String = UUID().uuidString, session: URLSession = .shared) async throws -> String {
        guard let held = stored() else { throw Trouble.notSetUp }

        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)

        var request = URLRequest(url: URL(string: "https://api.switch-bot.com/v1.1/devices/\(held.deviceId)/commands")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(held.token, forHTTPHeaderField: "Authorization")
        request.setValue(sign(token: held.token, secret: held.secret, milliseconds: milliseconds, nonce: nonce), forHTTPHeaderField: "sign")
        request.setValue(String(milliseconds), forHTTPHeaderField: "t")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue("application/json; charset=utf8", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": held.preferPress ? "press" : "turnOn",
            "parameter": "default",
            "commandType": "command"
        ])

        let (data, _) = try await session.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (body["statusCode"] as? NSNumber)?.intValue ?? -1

        guard code == 100 else { throw Trouble.refused(Self.wording(code, held.name)) }

        return "I've pressed \(held.name), sir."
    }

    /// SwitchBot's status codes, in terms of what the owner can do about them.
    static func wording(_ code: Int, _ name: String) -> String {
        switch code {
        case 151, 152: return "SwitchBot doesn't recognise \(name) any more, sir. It may need assigning again."
        case 160: return "SwitchBot wouldn't accept that command, sir."
        case 161: return "\(name) is offline, sir."
        case 171: return "The hub is offline, sir, so \(name) can't be reached."
        case 190: return "SwitchBot refused the request, sir."
        case 401: return "The SwitchBot credentials on this phone are no longer valid, sir."
        default: return "SwitchBot wouldn't press \(name), sir (\(code))."
        }
    }
}
