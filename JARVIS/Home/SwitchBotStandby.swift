import CryptoKit
import Foundation

/// The SwitchBot account's two credentials, as this phone holds them.
///
/// Kept in the Keychain, device-only and never synchronised, and never in UserDefaults, a log line,
/// an analytics event or a notification payload. `description` prints nothing, so a credential cannot
/// reach a log through string interpolation - the protection the PC's own `SwitchBotCredentials` has,
/// for the same reason and tested the same way.
///
/// **Typed into this phone by the owner, not sent by the PC.** The PC has its own copy in its
/// protected store, and nothing exports it: a bridge request that could hand a token over would be a
/// way to steal the account from any phone that ever paired. Two copies of a token the owner can
/// revoke in one tap is the cheaper risk.
struct SwitchBotCredentials: Equatable, CustomStringConvertible {
    let token: String
    let secret: String

    var description: String { "SwitchBotCredentials(***)" }

    var usable: Bool { !token.isEmpty && !secret.isEmpty }

    private static let account = "switchbot-standby"

    static func load() -> SwitchBotCredentials? {
        guard let data = Keychain.read(account),
              let pair = try? JSONDecoder().decode(Stored.self, from: data),
              !pair.token.isEmpty, !pair.secret.isEmpty
        else { return nil }

        return SwitchBotCredentials(token: pair.token, secret: pair.secret)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(Stored(token: token, secret: secret)) else { return }
        Keychain.write(Self.account, data)
    }

    static func forget() { Keychain.delete(account) }

    private struct Stored: Codable {
        let token: String
        let secret: String
    }
}

/// SwitchBot OpenAPI v1.1 request signing.
///
/// The same function as the PC's `SwitchBotAuth`, and deliberately the same words: the string to
/// sign is the token, the timestamp in milliseconds and the nonce concatenated with nothing between
/// them; it is signed with HMAC-SHA256 keyed by the secret; the signature is Base64 and then upper
/// case. It travels in four headers - `Authorization` (the token), `sign`, `t` and `nonce`.
///
/// Pure, so a test can hold it to a value worked out independently. That matters more here than
/// anywhere: a wrong signature and a wrong expectation written by the same hand agree with each
/// other, and the only thing that catches it is a vector the PC's own test already pins.
enum SwitchBotAuth {
    static func sign(token: String, secret: String, milliseconds: Int64, nonce: String) -> String {
        let payload = Data((token + String(milliseconds) + nonce).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString().uppercased()
    }

    /// The four headers for one request.
    static func headers(_ credentials: SwitchBotCredentials, milliseconds: Int64, nonce: String) -> [String: String] {
        [
            "Authorization": credentials.token,
            "sign": sign(token: credentials.token, secret: credentials.secret, milliseconds: milliseconds, nonce: nonce),
            "t": String(milliseconds),
            "nonce": nonce
        ]
    }
}

/// SwitchBot's wire format, in and out, with nothing about HTTP in it.
///
/// Every response is an envelope - `statusCode`, `message`, `body` - and the HTTP status is 200 even
/// when the command failed: a Bot whose hub is unplugged answers 200 with `statusCode: 171`. So
/// success is read from the envelope, never from the HTTP line alone. Authentication is the one
/// exception and fails at the HTTP layer with 401.
enum SwitchBotApi {
    static let baseUrl = "https://api.switch-bot.com/v1.1"

    // Documented codes, matching the PC's own list.
    static let success = 100
    static let deviceTypeError = 151
    static let deviceNotFound = 152
    static let commandNotSupported = 160
    static let deviceOffline = 161
    static let hubOffline = 171
    static let deviceSyncError = 190

    /// A command body, exactly as the vendor documents it.
    static func commandBody(_ command: StandbyCommand) -> Data {
        let verb: String
        switch command {
        case .on: verb = "turnOn"
        case .off: verb = "turnOff"
        case .press: verb = "press"
        }
        return Data(#"{"command":"\#(verb)","parameter":"default","commandType":"command"}"#.utf8)
    }

    /// An envelope's three parts, or nil when the text is not an envelope at all.
    static func envelope(_ data: Data) -> (statusCode: Int, message: String?, body: [String: Any])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["statusCode"] as? Int
        else { return nil }

        return (code, json["message"] as? String, json["body"] as? [String: Any] ?? [:])
    }

    /// What a status body says the power is, when it says anything.
    static func power(_ body: [String: Any]) -> Bool? {
        switch (body["power"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// The battery percentage, when there is one.
    static func battery(_ body: [String: Any]) -> Int? {
        guard let value = (body["battery"] as? NSNumber)?.intValue else { return nil }
        return min(max(value, 0), 100)
    }
}

/// What the phone can ask a device to do while the PC is off.
enum StandbyCommand: Equatable {
    case on
    case off
    case press
}

/// How a command sent straight to the vendor turned out.
///
/// Five states, and the distinction between the first two is the whole point: SwitchBot accepting a
/// command means the cloud has it, not that the rocker moved. Only a status read that comes back
/// saying "on" is a confirmation, and until one does the phone says "sent", which is what it knows.
enum StandbyOutcome: Equatable {
    /// The vendor accepted it. Nothing has confirmed the switch actually moved.
    case sent
    /// A status read came back and says this is the state now.
    case confirmed(on: Bool)
    /// The hub or the device could not be reached. The command did not happen.
    case offline(String)
    /// Refused, or the account was not accepted. The command did not happen.
    case failed(String)
    /// Nothing to try: no credential on this phone, no binding for the device, or no network.
    case unavailable(String)
    /// It may have been carried out, and nothing may retry it.
    ///
    /// A request that times out after it left may have reached the hub and pressed the switch, with
    /// only the answer lost coming back - and sending it again would press a physical rocker twice.
    /// The PC's provider has exactly this rule; a phone that retried where the PC would not would
    /// be the worse of the two.
    case ambiguous(String)

    /// What to show the owner. Never a claim that the light changed unless something confirmed it.
    var sentence: String {
        switch self {
        case .sent: return "Sent. I can't confirm it from here until I read it back."
        case .confirmed(let on): return on ? "Confirmed on." : "Confirmed off."
        case .offline(let why): return why
        case .failed(let why): return why
        case .unavailable(let why): return why
        case .ambiguous(let why): return why
        }
    }

    /// Whether the command reached the vendor at all.
    var reached: Bool {
        switch self {
        case .sent, .confirmed: return true
        case .offline, .failed, .unavailable, .ambiguous: return false
        }
    }
}

/// Talks to SwitchBot directly, and only when the PC cannot.
///
/// Normally every command goes phone → PC → vendor, and that is right: the PC is where the device
/// service lives, where the state is kept and where one light has one authority. This is the
/// exception the hardware forces, because a PC that is off is not a hop.
///
/// It deliberately knows nothing about when to be used. `StandbyRoute` decides that.
struct SwitchBotStandby {
    /// Everything a test needs to pin: the clock, the nonce, and the transport.
    struct Wiring {
        var milliseconds: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
        var nonce: () -> String = { UUID().uuidString }
        var send: (URLRequest) async throws -> (Data, URLResponse)

        static let live = Wiring { request in
            let session = URLSession(configuration: .ephemeral)
            return try await session.data(for: request)
        }
    }

    let credentials: SwitchBotCredentials
    var wiring: Wiring = .live
    var timeout: TimeInterval = 15

    /// Sends one command, once, and never twice.
    func send(_ command: StandbyCommand, to vendorDeviceId: String) async -> StandbyOutcome {
        guard let url = URL(string: "\(SwitchBotApi.baseUrl)/devices/\(escaped(vendorDeviceId))/commands") else {
            return .failed("That device can't be addressed.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf8", forHTTPHeaderField: "Content-Type")
        request.httpBody = SwitchBotApi.commandBody(command)

        return await call(request, pressing: true)
    }

    /// Reads a device's state now, so "sent" can become "confirmed".
    func read(_ vendorDeviceId: String) async -> (outcome: StandbyOutcome, battery: Int?) {
        guard let url = URL(string: "\(SwitchBotApi.baseUrl)/devices/\(escaped(vendorDeviceId))/status") else {
            return (.failed("That device can't be addressed."), nil)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let (data, outcome) = await raw(request, pressing: false)

        guard outcome == nil, let data, let envelope = SwitchBotApi.envelope(data) else {
            return (outcome ?? .failed("SwitchBot sent something I couldn't read."), nil)
        }

        guard envelope.statusCode == SwitchBotApi.success else {
            return (problem(envelope.statusCode, envelope.message), nil)
        }

        // A Bot sitting on a rocker reports no power state at all, and that is not a failure: the
        // command was accepted and there is simply nothing to confirm it against.
        guard let on = SwitchBotApi.power(envelope.body) else {
            return (.sent, SwitchBotApi.battery(envelope.body))
        }

        return (.confirmed(on: on), SwitchBotApi.battery(envelope.body))
    }

    private func call(_ request: URLRequest, pressing: Bool) async -> StandbyOutcome {
        let (data, outcome) = await raw(request, pressing: pressing)

        if let outcome { return outcome }

        guard let data, let envelope = SwitchBotApi.envelope(data) else {
            return .failed("SwitchBot sent something I couldn't read.")
        }

        return envelope.statusCode == SwitchBotApi.success ? .sent : problem(envelope.statusCode, envelope.message)
    }

    /// One signed request. Returns the body, or the outcome when it never got to one.
    private func raw(_ request: URLRequest, pressing: Bool) async -> (Data?, StandbyOutcome?) {
        var signed = request
        for (header, value) in SwitchBotAuth.headers(credentials, milliseconds: wiring.milliseconds(), nonce: wiring.nonce()) {
            signed.setValue(value, forHTTPHeaderField: header)
        }

        do {
            let (data, response) = try await wiring.send(signed)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 401, 403:
                    return (nil, .failed("SwitchBot didn't accept the token on this phone. Check it in Settings."))
                case 429:
                    return (nil, .failed("SwitchBot is rate-limiting this account. Try again shortly."))
                default:
                    return (nil, .failed("SwitchBot answered \(http.statusCode)."))
                }
            }

            return (data, nil)
        } catch let error as URLError where error.code == .timedOut && pressing {
            // It may have gone through. Nothing retries it; see StandbyOutcome.ambiguous.
            return (nil, .ambiguous("I sent it, but SwitchBot stopped answering, so I can't say whether it went through. I won't send it again."))
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
            return (nil, .unavailable("This phone has no connection, so I can't reach SwitchBot either."))
        } catch let error as URLError where error.code == .timedOut {
            return (nil, .offline("SwitchBot didn't answer in time."))
        } catch {
            return (nil, .offline("I couldn't reach SwitchBot."))
        }
    }

    /// A vendor status code in JARVIS's words. Never the number.
    private func problem(_ code: Int, _ message: String?) -> StandbyOutcome {
        switch code {
        case SwitchBotApi.hubOffline:
            return .offline("The SwitchBot Hub isn't online, so the command couldn't be relayed. If it's powered from the PC's USB, it will be off too.")
        case SwitchBotApi.deviceOffline:
            return .offline("The device isn't answering the hub.")
        case SwitchBotApi.deviceNotFound:
            return .failed("SwitchBot doesn't know that device any more. Re-bind it on the PC.")
        case SwitchBotApi.deviceTypeError, SwitchBotApi.commandNotSupported:
            return .failed("That device doesn't take that command.")
        case SwitchBotApi.deviceSyncError:
            return .offline("SwitchBot couldn't sync with the device.")
        default:
            return .failed(message.map { "SwitchBot refused it: \($0)" } ?? "SwitchBot refused it.")
        }
    }

    private func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }
}
