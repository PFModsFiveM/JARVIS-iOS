import Foundation

/// Working a device from this phone alone, with nothing of the app around it.
///
/// `SmartHomeModel` owns what the screens show and needs the whole app to exist. Siri does not have
/// that: an App Intent may run with no window on screen, and the widget less still. Both need the
/// same two steps in the same order with the same wording, and two copies of "accepted is not
/// confirmed" is exactly the kind of duplication that ends with one of them lying.
///
/// So this is the execution authority for the direct route - send once, read back, say what is
/// actually known - and `SmartHomeModel` is a layer of published state on top of it rather than a
/// second implementation beside it.
enum StandbyExecutor {
    /// What happened, in enough detail for a screen and for a sentence.
    struct Done: Equatable {
        let outcome: StandbyOutcome
        /// The state a read-back confirmed, or nil when nothing confirmed one.
        let confirmed: Bool?
        let battery: Int?

        var sentence: String { outcome.sentence }
    }

    /// Sends one command and then reads the device back.
    ///
    /// Two steps on purpose. SwitchBot accepting a command means the cloud has it, not that the
    /// rocker moved, so nothing is claimed about the switch until a status read says so. A read
    /// that reports no power state - which is what a Bot on a push button does - leaves it at
    /// "sent", because that is the whole truth.
    static func perform(
        _ command: StandbyCommand,
        on binding: StandbyDevice,
        credentials: SwitchBotCredentials,
        wiring: SwitchBotStandby.Wiring = .live
    ) async -> Done {
        let vendor = SwitchBotStandby(credentials: credentials, wiring: wiring)
        let sent = await vendor.send(command, to: binding.vendorDeviceId)

        guard sent.reached else { return Done(outcome: sent, confirmed: nil, battery: nil) }

        let (confirmation, battery) = await vendor.read(binding.vendorDeviceId)

        if case .confirmed(let on) = confirmation {
            return Done(outcome: confirmation, confirmed: on, battery: battery)
        }

        return Done(outcome: confirmation, confirmed: nil, battery: battery)
    }

    /// The binding a name or a JARVIS id refers to, or nil when that is not one device.
    ///
    /// Exact id, then exact name, then a name that contains what was said - the same ladder the
    /// PC's own device tool uses, so naming a device out loud and naming it in Shortcuts resolve
    /// the same way. Ambiguity returns nil rather than the first match.
    static func binding(named said: String, in bindings: [StandbyDevice]) -> StandbyDevice? {
        let wanted = said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }

        if let exact = bindings.first(where: { $0.id.lowercased() == wanted }) { return exact }
        if let exact = bindings.first(where: { $0.name.lowercased() == wanted }) { return exact }

        let contains = bindings.filter { $0.name.lowercased().contains(wanted) }
        return contains.count == 1 ? contains.first : nil
    }

    /// What this phone can say about a direct route right now, without sending anything.
    ///
    /// For a diagnostic and for a screen that has to decide whether to offer a switch. Deliberately
    /// the same decision `StandbyRoute` makes, asked without a command.
    static func canActAlone(_ bindings: [StandbyDevice], credentials: SwitchBotCredentials?) -> Bool {
        credentials?.usable == true && bindings.contains { $0.provider == "SwitchBot" }
    }
}
