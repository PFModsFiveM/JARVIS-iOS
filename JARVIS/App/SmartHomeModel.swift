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

    /// Whether ON and OFF mean different things. False for a Bot on a push button, where they do not.
    var canSwitch: Bool { bound && capabilities.contains("powerOn") && status != .notSetUp }

    /// Whether a single press can be asked for. The only control a push-button Bot has, so a screen
    /// that offers nothing when this is true and `canSwitch` is false leaves the device unreachable
    /// from the phone while the PC and voice can still work it.
    var canPress: Bool { bound && capabilities.contains("press") && status != .notSetUp }
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
/// **When the PC is away.** The command normally goes phone → PC → SwitchBot, and that stays the
/// first choice whenever the PC is answering: the PC owns the state, confirms the switch and tells
/// every other phone what changed. A PC that is off, though, is not a hop - so when the bridge is
/// not answering and this phone has both its own SwitchBot token and a binding the PC taught it,
/// the command goes straight to the vendor instead. `StandbyRoute` makes that decision, once, for
/// every screen.
///
/// What it will not do is pretend. Without a token or a binding the screen says so and offers the
/// wake button instead of a switch that fails; a command the vendor accepted says "sent" until a
/// status read confirms it; and with the PC off the state of a light nobody has read is shown as
/// unknown rather than as whatever it was when the PC last spoke.
@MainActor
final class SmartHomeModel: ObservableObject {
    static let shared = SmartHomeModel()

    @Published private(set) var devices: [SmartDevice] = []
    @Published private(set) var simulating = false
    @Published private(set) var loaded = false
    /// The last thing that went wrong, in JARVIS's words, per device. Cleared by the next command.
    @Published private(set) var messages: [String: String] = [:]

    /// What this phone can work by itself, as the PC last described it. Empty until it has.
    @Published private(set) var standby: [StandbyDevice] = StandbyBindings.load()

    /// The SwitchBot token this phone holds, if the owner has given it one.
    @Published private(set) var credentials: SwitchBotCredentials? = SwitchBotCredentials.load()

    private let model: AppModel

    /// Pinned by the tests; the live one talks to SwitchBot.
    var wiring: SwitchBotStandby.Wiring = .live

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// The owner's own SwitchBot token, kept in the Keychain and nowhere else.
    func remember(token: String, secret: String) {
        let pair = SwitchBotCredentials(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))

        guard pair.usable else { return }

        pair.save()
        credentials = pair
    }

    /// Forgets it. The PC's own copy is untouched; this only stops the phone acting alone.
    func forgetCredentials() {
        SwitchBotCredentials.forget()
        credentials = nil
    }

    /// Whether this device can be worked at all right now, by either route.
    ///
    /// What the panel enables its switch on. Previously it enabled on "the PC is answering", which
    /// was the whole of the truth then and is not now.
    func canWork(_ device: SmartDevice) -> Bool {
        route(device.id, device.canSwitch ? .on : .press).possible
    }

    /// The route one command would take. Exposed so a screen can explain itself.
    func route(_ id: String, _ command: StandbyCommand) -> StandbyRoute {
        StandbyRoute.of(id,
                        pcIsAnswering: model.link.isOnline,
                        command: command,
                        credentials: credentials,
                        bindings: standby)
    }

    /// Whether anything at all can be switched from this phone right now, and why not when nothing can.
    ///
    /// One sentence for the screens, so the panel and the chat say the same thing.
    var standbySummary: String? {
        if model.link.isOnline { return nil }
        if credentials == nil {
            return "Your PC isn't answering. Add this phone's own SwitchBot token in Settings and it can still switch the light."
        }
        if standby.isEmpty {
            return "Your PC isn't answering, and it hasn't told this phone how to reach anything yet. Connect once while it's on."
        }
        return "Your PC isn't answering, so these are going straight to SwitchBot."
    }

    /// One room's devices.
    struct Room: Identifiable {
        let room: String
        let devices: [SmartDevice]
        var id: String { room }
    }

    /// What to draw.
    ///
    /// The PC's list whenever there is one. With the PC off since launch there is not, and a panel
    /// with nothing in it would be the old behaviour dressed up - so the standby bindings stand in,
    /// with every state shown as unknown. Unknown is the truth: nothing has read the switch.
    var shown: [SmartDevice] {
        guard devices.isEmpty else { return devices }

        return standby.compactMap {
            standbyRow($0, status: "unknown", certainty: "unknown",
                       statusText: "Not known while your PC is off", battery: nil, problem: nil)
        }
    }

    /// The devices grouped by room, rooms in order, a device with no room last.
    var rooms: [Room] {
        Dictionary(grouping: shown, by: { $0.room ?? "Elsewhere" })
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

        await learnStandby(client)
    }

    /// Asks the PC what this phone could work without it, and remembers the answer.
    ///
    /// Asked while the PC is up, because it cannot be asked when it is down - which is the whole
    /// point. Quietly: a PC that predates this request answers "failed", and what the phone already
    /// learned stays as it was rather than being wiped by an older PC.
    func learnStandby(_ client: BridgeClient) async {
        guard let reply = try? await client.request("devices.standby"), reply.kind == "devices.standby" else { return }

        let learned = (reply.body["devices"] as? [[String: Any]] ?? []).compactMap(StandbyDevice.init)

        standby = learned
        StandbyBindings.save(learned)
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

    /// Works a device named by JARVIS's id, and says in one sentence what happened.
    ///
    /// For the spoken and typed paths, which name a device rather than tapping a row, and which may
    /// be running with the PC off and no device list to tap. Goes through exactly the same routing
    /// and the same wording as the panel's switch, so the two cannot drift.
    func work(_ id: String, _ want: StandbyCommand) async -> String {
        guard let device = shown.first(where: { $0.id == id }) else {
            return MobilePhrases.noSuchDevice()
        }

        switch want {
        case .on: await setPower(device, on: true)
        case .off: await setPower(device, on: false)
        case .press: await press(device)
        }

        if let said = messages[id] { return said }

        // Nothing went wrong and nothing needed explaining, which is the PC path confirming it.
        let after = shown.first(where: { $0.id == id })

        switch want {
        case .on:
            return after?.isOn == true
                ? MobilePhrases.switchedOn(device.name)
                : MobilePhrases.sentButUnconfirmed(device.name, after?.statusText ?? "")
        case .off:
            return after?.isOff == true
                ? MobilePhrases.switchedOff(device.name)
                : MobilePhrases.sentButUnconfirmed(device.name, after?.statusText ?? "")
        case .press:
            return MobilePhrases.pressed(device.name)
        }
    }

    /// Works a device the other way from however it is now - "switch the bedroom light".
    ///
    /// Only when the state is actually known. A toggle against an unknown state is a coin toss
    /// dressed as a command, and the one place this is most likely to be asked is with the PC off,
    /// where a light nobody has read is exactly that. So it says what it does not know and offers
    /// the two commands that need no knowledge, rather than guessing and being right half the time.
    func toggle(_ id: String) async -> String {
        guard let device = shown.first(where: { $0.id == id }) else {
            return MobilePhrases.noSuchDevice()
        }

        if device.isOn { return await work(id, .off) }
        if device.isOff { return await work(id, .on) }

        return MobilePhrases.cannotToggleUnknown(device.name)
    }

    private func command(_ device: SmartDevice, kind: String, body: [String: Any]) async {
        messages[device.id] = nil
        replace(device.pending())

        let wanted: StandbyCommand = kind == "devices.press" ? .press : (body["on"] as? Bool == true ? .on : .off)

        switch StandbyRoute.of(device.id,
                               pcIsAnswering: model.link.isOnline,
                               command: wanted,
                               credentials: credentials,
                               bindings: standby) {
        case .pc:
            await throughThePC(device, kind: kind, body: body, wanted: wanted)
        case .direct(let binding):
            await straightToTheVendor(device, binding: binding, wanted: wanted)
        case .nothing(let why):
            messages[device.id] = why
            replace(device)
        }
    }

    /// The normal path, and the preferred one: the PC decides, carries it out and confirms.
    private func throughThePC(_ device: SmartDevice, kind: String, body: [String: Any], wanted: StandbyCommand) async {
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
            // The PC stopped answering between the route decision and the request. Rather than
            // reporting a failure that is not the light's fault, take the other route if there is
            // one - which is exactly the case this feature was built for.
            switch StandbyRoute.of(device.id, pcIsAnswering: false, command: wanted,
                                   credentials: credentials, bindings: standby) {
            case .direct(let binding):
                await straightToTheVendor(device, binding: binding, wanted: wanted)
            case .pc, .nothing:
                messages[device.id] = "Couldn't reach your PC, so \(device.name) wasn't switched."
                replace(device)
            }
        }
    }

    /// The PC-off path: this phone's own token, straight to SwitchBot, and then read back.
    ///
    /// Two steps on purpose. SwitchBot accepting a command means the cloud has it, not that the
    /// rocker moved, so the state is shown as updating and the sentence says "sent" until a status
    /// read comes back. A read that says nothing - which is what a Bot on a push button reports -
    /// leaves it at "sent", because that is the whole truth.
    private func straightToTheVendor(_ device: SmartDevice, binding: StandbyDevice, wanted: StandbyCommand) async {
        guard let credentials else {
            messages[device.id] = "This phone has no SwitchBot token of its own."
            replace(device)
            return
        }

        // The send and the read-back are `StandbyExecutor`'s, so Siri, the widget and this screen
        // cannot drift on what "sent" means.
        let done = await StandbyExecutor.perform(wanted, on: binding, credentials: credentials, wiring: wiring)

        messages[device.id] = done.sentence

        guard let on = done.confirmed else {
            show(unknown(binding, because: done.sentence), orKeep: device)
            return
        }

        show(standbyRow(binding, status: on ? "on" : "off", certainty: "confirmed",
                        statusText: on ? "On (confirmed without the PC)" : "Off (confirmed without the PC)",
                        battery: done.battery, problem: nil),
             orKeep: device)
    }

    /// The device with its state honestly unknown, and why.
    private func unknown(_ binding: StandbyDevice, because: String) -> SmartDevice? {
        standbyRow(binding, status: "unknown", certainty: "unknown",
                   statusText: "Not known while your PC is off", battery: nil, problem: because)
    }

    /// Shows a row built from a binding, or leaves the device as it was if one could not be built.
    ///
    /// `SmartDevice`'s decoder is the only one in the app, and it refuses a row with no id or name.
    /// A binding always has both, so this never falls back in practice - but going through the same
    /// decoder as the PC's own rows is worth more than the certainty of a force-unwrap.
    private func show(_ built: SmartDevice?, orKeep fallback: SmartDevice) {
        replace(built ?? fallback)
    }

    /// A device row built from a standby binding rather than from the PC.
    ///
    /// Through `SmartDevice`'s own decoder, so there is one shape and one set of rules about what
    /// each field means, whoever supplied it. `simulated` is false and `bound` is true because both
    /// are facts about the device, not about who is talking to it.
    private func standbyRow(
        _ binding: StandbyDevice,
        status: String,
        certainty: String,
        statusText: String,
        battery: Int?,
        problem: String?
    ) -> SmartDevice? {
        var row: [String: Any] = [
            "id": binding.id,
            "name": binding.name,
            "kind": binding.kind,
            "status": status,
            "statusText": statusText,
            "certainty": certainty,
            "updating": false,
            "bound": true,
            "simulated": false,
            "capabilities": binding.switches ? ["powerOn", "powerOff", "press"] : ["press"]
        ]
        if let room = binding.room { row["room"] = room }
        if let battery { row["battery"] = NSNumber(value: battery) }
        if let problem { row["problem"] = problem }

        return SmartDevice(row)
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
