import Foundation

/// What kind of thing a device is, which decides what can be done to it.
///
/// The list is short because it is honest: JARVIS controls one PC today, and knows about the other
/// machines on its network well enough to switch them on. Lights, heating and the rest arrive as
/// cases here when the PC can actually do something with them - an empty row for a light that does
/// not exist is worse than no row.
enum DeviceKind: String, Codable {
    /// The PC this phone is paired with: everything can be done to it.
    case pc

    /// Another machine on the PC's network. It can be woken, and nothing else - JARVIS is not
    /// running on it, so there is no one there to be asked to sleep.
    case machine
}

/// One thing in the house that JARVIS can do something to.
struct ControlledDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: DeviceKind

    /// Where it was last seen, for the second line. Empty when there is nothing useful to say.
    let detail: String

    /// Whether JARVIS believes it is on and reachable now.
    let awake: Bool

    /// Whether it can be switched on from here at all - it needs a network card JARVIS knows.
    let wakeable: Bool
}

/// One thing that can be done to a device, and how seriously to take it.
struct DeviceAction: Identifiable {
    let id: String
    let title: String

    /// Whether to ask before doing it. The ones that end somebody's session do.
    let confirm: String?

    /// The tint, by how much it would cost to press by accident.
    let severity: Severity

    enum Severity { case ordinary, careful, grave, good }
}

/// The things in the house, and doing them.
///
/// **The PC is two devices in one and that is the point.** Wake-on-LAN is the only thing that works
/// while it is off - it is a packet to a network card, not a request to JARVIS - and everything
/// else needs it awake and answering. So "turn on" comes from the phone itself and the rest go over
/// the bridge, and the panel does not pretend they are the same kind of button.
@MainActor
final class HomeControlModel: ObservableObject {
    static let shared = HomeControlModel()

    /// Other machines the PC knows how to wake, learnt from its own network rather than typed.
    @Published private(set) var machines: [ControlledDevice] = []

    @Published private(set) var refreshing = false

    private let model: AppModel

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// The PC itself, as a device.
    ///
    /// Built from values handed in rather than read off the app model, and that is not fussiness:
    /// an ObservableObject only tells SwiftUI about its own published properties, so a row computed
    /// from another object's state would sit there saying "Awake" after the PC had gone. The view
    /// watches the app model and passes what it sees.
    ///
    /// Always present, even when it is off - that is exactly when somebody wants to switch it on,
    /// and a list that hides the thing you came to press has missed the point.
    nonisolated static func pc(name: String?, online: Bool, wakeable: Bool) -> ControlledDevice {
        ControlledDevice(
            id: "pc",
            name: name?.isEmpty == false ? name! : "Your PC",
            kind: .pc,
            detail: online ? "Awake" : "Not answering",
            awake: online,
            wakeable: wakeable)
    }

    /// What can be done to a device, in the order a person would reach for them.
    ///
    /// Static because it depends on nothing but the kind of thing it is, which also means the list
    /// can be checked by a test without standing up an app that wants a paired PC.
    nonisolated static func actions(for device: ControlledDevice) -> [DeviceAction] {
        switch device.kind {
        case .pc:
            return [
                DeviceAction(id: "wake", title: "Turn on", confirm: nil, severity: .good),
                DeviceAction(id: "lock", title: "Lock", confirm: nil, severity: .ordinary),
                DeviceAction(id: "sleep", title: "Sleep", confirm: "Put the PC to sleep?", severity: .careful),
                DeviceAction(id: "restart", title: "Restart", confirm: "Restart the PC?", severity: .careful),
                DeviceAction(id: "shutdown", title: "Shut down", confirm: "Shut down the PC?", severity: .grave),
                DeviceAction(id: "cancel", title: "Cancel restart / shut-down", confirm: nil, severity: .good)
            ]

        case .machine:
            // One button, because one thing is true: a magic packet can switch it on, and nothing
            // here is running on it to be asked for anything else.
            return [DeviceAction(id: "wake", title: "Turn on", confirm: nil, severity: .good)]
        }
    }

    /// Does one of them.
    func perform(_ action: DeviceAction, on device: ControlledDevice) async {
        switch (device.kind, action.id) {
        case (.pc, "wake"):
            // From this phone, not through the PC: the PC is asleep, which is the whole reason.
            model.wakePC()

        case (.pc, "lock"):
            await model.securityAction("lock")

        case (.pc, _):
            await ControlModel.shared.power(action.id)

        case (.machine, "wake"):
            await wake(machine: device)

        default:
            break
        }
    }

    /// Asks the PC to wake another machine on its network.
    ///
    /// Through the PC rather than from here, because this phone does not know that machine's card -
    /// the PC learnt it from its own network - and because a phone on mobile data cannot broadcast
    /// onto a home network at all.
    private func wake(machine: ControlledDevice) async {
        do {
            let client = try await model.session()

            let reply = try await client.approvedRequest(
                "machine.wake",
                reason: "Turn on \(machine.name)",
                ["machine": machine.name])

            model.toast = reply.message
        } catch {
            model.toast = "Couldn't reach the PC to wake \(machine.name)."
        }
    }

    /// Asks the PC what else is on its network.
    ///
    /// Quietly: an older PC that does not know the request answers "failed", and this keeps
    /// whatever it already had rather than emptying the list.
    func refresh() async {
        guard !refreshing, model.link.isOnline else { return }

        refreshing = true
        defer { refreshing = false }

        guard let client = try? await model.session(),
              let reply = try? await client.request("machines"),
              reply.kind == "machines",
              let rows = reply.body["machines"] as? [[String: Any]]
        else { return }

        machines = Self.read(rows)
    }

    /// The machines out of a reply, keeping only the ones there is a button for.
    ///
    /// A machine with no network card recorded cannot be woken, and a row whose only action would
    /// fail is a row that should not be drawn.
    nonisolated static func read(_ rows: [[String: Any]]) -> [ControlledDevice] {
        rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  row["wakeable"] as? Bool == true
            else { return nil }

            let address = row["address"] as? String ?? ""

            return ControlledDevice(
                id: "machine:\(name)",
                name: name,
                kind: .machine,
                detail: address.isEmpty ? "On your network" : "Last seen at \(address)",
                awake: false,
                wakeable: true)
        }
    }
}
