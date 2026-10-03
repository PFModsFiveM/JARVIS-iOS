import Foundation

/// What this phone was told it can work while the PC is off.
///
/// Learned from the PC over the paired bridge (`devices.standby`) whenever the PC is reachable, and
/// kept in the Keychain rather than UserDefaults - not because a device id is a secret, but because
/// it says which switch in this house is which, and that belongs with the pairing rather than in a
/// file a backup copies anywhere.
///
/// **The vendor id never leaves this type.** Nothing shows it, nothing logs it, and the screens and
/// the voice path address a device by JARVIS's own id (`bedroom_main_light`) exactly as they do when
/// the PC is answering. `description` prints the JARVIS id and withholds the rest.
struct StandbyDevice: Codable, Equatable, Identifiable, CustomStringConvertible {
    let id: String
    let name: String
    let room: String?
    let kind: String
    let provider: String
    let vendorDeviceId: String
    let preferPress: Bool

    var description: String { "StandbyDevice(\(id), \(provider), ***)" }

    /// Whether on and off mean different things here, or only a press does.
    var switches: Bool { !preferPress }

    /// One row of a `devices.standby` reply, or nil for anything incomplete.
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty,
              let vendor = row["providerDeviceId"] as? String, !vendor.isEmpty,
              let provider = row["provider"] as? String, !provider.isEmpty
        else { return nil }

        self.id = id
        name = row["name"] as? String ?? id
        room = row["room"] as? String
        kind = row["kind"] as? String ?? "light"
        self.provider = provider
        vendorDeviceId = vendor
        preferPress = row["preferPress"] as? Bool ?? false
    }
}

/// The bindings, kept across launches.
enum StandbyBindings {
    private static let account = "standby-devices"

    static func load() -> [StandbyDevice] {
        guard let data = Keychain.read(account),
              let devices = try? JSONDecoder().decode([StandbyDevice].self, from: data)
        else { return [] }

        return devices
    }

    static func save(_ devices: [StandbyDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        Keychain.write(account, data)
    }

    static func forget() { Keychain.delete(account) }
}

/// Which way a device command goes, and whether there is a way at all.
///
/// The one decision this whole feature turns on, in one place, so the chat path, the device panel
/// and the widget cannot disagree about it. The order is not negotiable:
///
/// 1. **The PC, whenever the PC is answering.** It owns the device state, it confirms, it tells
///    every other phone what changed, and it keeps one light under one authority. A phone that
///    went direct while the PC was up would leave the PC's own state quietly wrong.
/// 2. **Straight to the vendor, only when the PC is not answering** and this phone has both a
///    credential and a binding for that device.
/// 3. **Nothing, said plainly.** Not a button that fails, and not a cheerful "done".
enum StandbyRoute: Equatable {
    case pc
    case direct(StandbyDevice)
    case nothing(String)

    /// Whether the command can happen at all.
    var possible: Bool {
        switch self {
        case .pc, .direct: return true
        case .nothing: return false
        }
    }

    /// Decides the route for one JARVIS device id.
    ///
    /// - Parameters:
    ///   - pcIsAnswering: whether the bridge is up right now. Not "was recently" - a command sent
    ///     to a PC that stopped answering is the failure this feature exists to fix.
    ///   - command: what is being asked for, so a push-button Bot is not offered on and off.
    static func of(
        _ deviceId: String,
        pcIsAnswering: Bool,
        command: StandbyCommand,
        credentials: SwitchBotCredentials?,
        bindings: [StandbyDevice]
    ) -> StandbyRoute {
        if pcIsAnswering { return .pc }

        guard let credentials, credentials.usable else {
            return .nothing("Your PC isn't answering, and this phone has no SwitchBot token of its own. Add one in Settings and I can switch the light without the PC.")
        }

        guard let device = bindings.first(where: { $0.id == deviceId }) else {
            return .nothing("Your PC isn't answering, and it hasn't told this phone how to reach that device yet. Connect once while the PC is on and I'll remember.")
        }

        if device.provider != "SwitchBot" {
            return .nothing("Your PC isn't answering, and \(device.name) is on \(device.provider), which this phone can't reach by itself yet.")
        }

        // Written out rather than folded into one switch with a where clause: in Swift a where
        // clause binds to the pattern immediately before it, not to every pattern in the case, so
        // "case .on, .off where x" would let .on through unconditionally. That is the kind of
        // mistake that reads correctly and ships a button that does nothing.
        switch command {
        case .press:
            // A device that genuinely switches should be switched, so the state afterwards is known.
            if device.switches {
                return .nothing("\(device.name) takes on and off rather than a press.")
            }
        case .on, .off:
            if !device.switches {
                return .nothing("\(device.name) is a Bot on a push button, so on and off mean the same thing to it. A press is what it takes.")
            }
        }

        return .direct(device)
    }
}
