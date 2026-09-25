import Foundation

/// One smart-home device as the PC describes it - the `BridgeDevice` shape, field for field.
///
/// The phone never talks to SwitchBot, or to any vendor. It asks the PC, the PC's Device Service
/// decides which provider switches the light, and this is what comes back: JARVIS's own id
/// (`bedroom_main_light`), the name the owner uses, and what is known about it and how well. The
/// vendor's device id is not in it and the vendor's credentials never leave the PC.
struct SmartDevice: Identifiable, Equatable {
    enum Status: String { case notSetUp, unknown, on, off, updating, offline, error }
    enum Certainty: String { case unknown, assumed, confirmed }

    let id: String
    let name: String
    let room: String?
    let kind: String
    let status: Status
    /// The PC's own words for the status - "On (unconfirmed)" - so both screens say the same thing.
    let statusText: String
    let certainty: Certainty
    let updating: Bool
    let bound: Bool
    let simulated: Bool
    let battery: Int?
    let capabilities: [String]
    let readAt: Date?
    let lastCommand: String?
    let lastResult: String?
    let lastSuccessAt: Date?
    /// What went wrong, in the words JARVIS would say it. Nil when nothing did.
    let problem: String?

    var canSwitch: Bool { bound && capabilities.contains("powerOn") && status != .notSetUp }
    var isOn: Bool { status == .on }
    var isOff: Bool { status == .off }

    /// Reads one device out of a reply or a push. Nil for anything without an id and a name.
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty, let name = row["name"] as? String else { return nil }

        self.id = id
        self.name = name
        room = row["room"] as? String
        kind = row["kind"] as? String ?? "light"
        status = Status(rawValue: row["status"] as? String ?? "") ?? .unknown
        statusText = row["statusText"] as? String ?? ""
        certainty = Certainty(rawValue: row["certainty"] as? String ?? "") ?? .unknown
        updating = row["updating"] as? Bool ?? false
        bound = row["bound"] as? Bool ?? false
        simulated = row["simulated"] as? Bool ?? false
        battery = (row["battery"] as? NSNumber)?.intValue
        capabilities = row["capabilities"] as? [String] ?? []
        readAt = SmartDevice.date(row["readAt"])
        lastCommand = row["lastCommand"] as? String
        lastResult = row["lastResult"] as? String
        lastSuccessAt = SmartDevice.date(row["lastSuccessAt"])
        problem = row["problem"] as? String
    }

    /// The same device, told it is on its way to a state - drawn at once, before the PC answers.
    func pending() -> SmartDevice {
        var copy = self
        copy.overrideStatus = .updating
        return copy
    }

    private var overrideStatus: Status?

    /// What to draw: the PC's status, unless this phone has just sent a command and is waiting.
    var shown: Status { overrideStatus ?? status }

    /// A date as the PC writes it. .NET gives seven fractional digits ("…12.3456789+00:00"), which is
    /// more than ISO8601DateFormatter is sure to accept, so the fraction is cut to milliseconds first.
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }

        if let dot = text.firstIndex(of: "."),
           let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(text.index(after: dot)..<end, with: String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The house's smart devices, through the PC.
///
/// **One Bedroom Light.** The PC's HUD, its voice and this phone all switch the same JARVIS device
/// through the same Device Service, and every change - whoever made it - is pushed to every phone as
/// `devices.changed`. So there is nothing here to keep in step with the PC: it shows what the PC last
/// said, and the PC says whenever anything changes.
///
/// **Honest while the PC is away.** The command goes phone → PC → SwitchBot, so with the PC off or
/// unreachable nothing can be switched from here, and the screen says that rather than showing a
/// switch that silently does nothing. Waking the PC is the way back, and it is on the same page.
@MainActor
final class SmartHomeModel: ObservableObject {
    static let shared = SmartHomeModel()

    @Published private(set) var devices: [SmartDevice] = []
    @Published private(set) var simulating = false
    @Published private(set) var loaded = false
    /// The last thing that went wrong, in JARVIS's words, per device. Cleared by the next command.
    @Published private(set) var messages: [String: String] = [:]

    private let model: AppModel

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// One room's devices.
    struct Room: Identifiable {
        let room: String
        let devices: [SmartDevice]
        var id: String { room }
    }

    /// The devices grouped by room, rooms in order, a device with no room last.
    var rooms: [Room] {
        Dictionary(grouping: devices, by: { $0.room ?? "Elsewhere" })
            .map { Room(room: $0.key, devices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                if lhs.room == "Elsewhere" { return false }
                if rhs.room == "Elsewhere" { return true }
                return lhs.room < rhs.room
            }
    }

    /// Asks the PC for every device. Quietly: a PC that predates smart-home devices answers
    /// "failed", and the list stays as it was rather than emptying.
    func refresh() async {
        guard model.link.isOnline,
              let client = try? await model.session(),
              let reply = try? await client.request("devices"),
              reply.kind == "devices"
        else { return }

        apply(list: reply.body["devices"] as? [[String: Any]] ?? [], simulating: reply.body["simulating"] as? Bool ?? false)
    }

    /// Reads one device now. The PC decides whether that costs a request to the vendor.
    func refresh(_ id: String) async {
        guard model.link.isOnline,
              let client = try? await model.session(),
              let reply = try? await client.request("devices.refresh", ["id": id]),
              let row = reply.object("device"),
              let device = SmartDevice(row)
        else { return }

        replace(device)
    }

    /// On or off. Drawn as updating at once; the PC's answer replaces it.
    func setPower(_ device: SmartDevice, on: Bool) async {
        await command(device, kind: "devices.power", body: ["id": device.id, "on": on])
    }

    /// A single press, for a device on a push button.
    func press(_ device: SmartDevice) async {
        await command(device, kind: "devices.press", body: ["id": device.id])
    }

    private func command(_ device: SmartDevice, kind: String, body: [String: Any]) async {
        messages[device.id] = nil
        replace(device.pending())

        do {
            let client = try await model.session()
            let reply = try await client.request(kind, body, timeout: 25)

            if let row = reply.object("device"), let after = SmartDevice(row) { replace(after) }

            if reply.body["accepted"] as? Bool == false {
                messages[device.id] = reply.text("message") ?? "\(device.name) could not be reached."
            } else if reply.kind == "failed" {
                messages[device.id] = reply.message
                replace(device)
            }
        } catch {
            // The PC did not answer at all, which is not the light's fault and is said as such.
            messages[device.id] = "Couldn't reach your PC, so \(device.name) wasn't switched."
            replace(device)
        }
    }

    /// A `devices.changed` push: one device, as the PC now sees it.
    func receive(_ message: BridgeMessage) {
        guard let row = message.object("device"), let device = SmartDevice(row) else { return }
        replace(device)
    }

    /// Replaces the whole list - from a `devices` reply.
    func apply(list rows: [[String: Any]], simulating: Bool) {
        devices = rows.compactMap(SmartDevice.init)
        self.simulating = simulating
        loaded = true
    }

    private func replace(_ device: SmartDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}
