import SwiftUI

/// The things in the house, and what can be done to them.
///
/// Sits at the top of the Home screen rather than in a tab of its own: iOS folds a sixth tab into a
/// "More" menu, which is where features go to be forgotten. The question "can I turn the PC on from
/// here" is answerable by looking, and the answer is in the same place as everything else JARVIS
/// can switch. Lights and the rest join this list when the PC can genuinely control them.
struct DevicesPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var home = HomeControlModel.shared
    @StateObject private var machine = MachineLink.shared

    /// The PC as a row, from state this view is watching, so it redraws when the PC goes.
    private var pc: ControlledDevice {
        HomeControlModel.pc(
            name: model.pc?.serviceName,
            online: model.link.isOnline,
            wakeable: model.wakeProfile.mac != nil,
            machine: machine.report)
    }

    var body: some View {
        VStack(spacing: 14) {
            // The lights and switches first: the thing somebody opens this tab to press.
            SmartHomePanel()

            HUDFrame(title: "This PC") {
                NavigationLink { DeviceControlView(device: pc) } label: { DeviceRow(device: pc) }
                    .buttonStyle(.plain)
            }

            if !home.machines.isEmpty {
                HUDFrame(title: "Also on your network") {
                    ForEach(home.machines) { machine in
                        NavigationLink { DeviceControlView(device: machine) } label: { DeviceRow(device: machine) }
                            .buttonStyle(.plain)
                    }

                    Text("JARVIS learnt these from your network rather than being told them. It can switch them on; it isn't running on them, so it can't do anything else.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }
            }
        }
        .task {
            await home.refresh()
            await SmartHomeModel.shared.refresh()

            // Only when JARVIS itself is not answering. While it is, it says everything the service
            // could and more, and opening a second connection to the same machine to be told what
            // this phone already knows would be work for nothing.
            if !model.link.isOnline { await machine.ask() }
        }
        .onChange(of: model.link.isOnline) { _, online in
            // Back online: the PC may have switched something while this phone could not hear it.
            if online { Task { await SmartHomeModel.shared.refresh() } }

            // And off: ask the machine what happened to it, so the row can say whether it went to
            // sleep or somebody just locked it.
            if !online { Task { await machine.ask(force: true) } }
        }
    }
}

/// One line in the list: what it is, and whether it is on.
private struct DeviceRow: View {
    let device: ControlledDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind == .pc ? "desktopcomputer" : "server.rack")
                .font(.title3)
                .foregroundStyle(device.awake ? HUD.accent : HUD.dim)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline).foregroundStyle(HUD.text)
                Text(device.detail).font(.footnote).foregroundStyle(HUD.dim)
            }

            Spacer()

            // Three states, because there are three: answering, on but not answering, and nothing
            // heard at all. Amber is the interesting one - the machine is there, JARVIS is not.
            Circle()
                .fill(device.awake ? HUD.good : (device.powered ? HUD.amber : HUD.dim.opacity(0.4)))
                .frame(width: 8, height: 8)

            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(HUD.dim)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// One device, and the buttons for it.
struct DeviceControlView: View {
    let device: ControlledDevice

    @EnvironmentObject var model: AppModel
    @StateObject private var home = HomeControlModel.shared
    @StateObject private var machine = MachineLink.shared
    @State private var confirming: DeviceAction?

    /// The device as it is now. For the PC that is whatever the app model currently says, so the
    /// page comes alive the moment it answers rather than showing what it was when it was opened.
    private var live: ControlledDevice {
        device.kind == .pc
            ? HomeControlModel.pc(
                name: model.pc?.serviceName,
                online: model.link.isOnline,
                wakeable: model.wakeProfile.mac != nil,
                machine: machine.report)
            : device
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HUDFrame(title: live.name) {
                    HStack {
                        Text(live.awake ? "Awake and answering" : live.detail)
                            .foregroundStyle(live.awake ? HUD.good : (live.powered ? HUD.amber : HUD.dim))
                        Spacer()

                        if machine.asking { ProgressView().tint(HUD.accent) }
                    }
                    .font(.footnote)

                    // Where that came from, when it did not come from JARVIS. Worth saying: it is
                    // the difference between JARVIS knowing and the machine being asked about
                    // itself, and they are not equally informed.
                    if !live.awake, live.kind == .pc, let report = machine.report {
                        Text("The machine itself says: \(report.described).")
                            .font(.footnote).foregroundStyle(HUD.dim)
                    }

                    // The PC's own page only: wakeState is about this phone waking the PC, and
                    // showing it under another machine's name would credit it with the wrong event.
                    if live.kind == .pc, let wake = model.wakeState {
                        Text(wake.detail).font(.footnote).foregroundStyle(HUD.amber)
                    }
                }

                HUDFrame(title: "Power") {
                    ForEach(HomeControlModel.actions(for: live)) { action in
                        Button(action.title) {
                            if action.confirm == nil { run(action) } else { confirming = action }
                        }
                        .buttonStyle(HUDButtonStyle(tint: tint(action.severity)))
                        .disabled(disabled(action))
                    }

                    Text(footnote).font(.footnote).foregroundStyle(HUD.dim)
                }

                HUDFrame(title: "Say it instead") {
                    // The same actions by voice, because a person with their hands full should not
                    // have to find a button. These are the words JARVIS's own parser matches.
                    ForEach(spoken, id: \.self) { line in
                        Text("\u{201C}\(line)\u{201D}").font(.footnote).foregroundStyle(HUD.dim)
                    }
                }
            }
            .padding(16)
        }
        .background(HUDBackdrop().ignoresSafeArea())
        .task {
            if device.kind == .pc, !model.link.isOnline { await machine.ask() }
        }
        .hudTitle(live.name)
        .toolbarBackground(HUD.panel, for: .navigationBar)
        .confirmationDialog(
            confirming?.confirm ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible)
        {
            if let action = confirming {
                Button(action.title, role: .destructive) { run(action) }
            }

            Button("Not now", role: .cancel) { confirming = nil }
        }
    }

    private func run(_ action: DeviceAction) {
        confirming = nil
        Task { await home.perform(action, on: live) }
    }

    /// Turning it on is the one thing that works while it is off; everything else needs it awake.
    private func disabled(_ action: DeviceAction) -> Bool {
        // Turning the PC on is the one thing that works while it is off, because this phone sends
        // the packet itself - so it is the one button not disabled by the PC being unreachable,
        // which is exactly when it is wanted.
        if live.kind == .pc, action.id == "wake" { return !live.wakeable }

        // Everything else goes through the PC, including waking another machine: that packet comes
        // from the PC's network, not from a phone that may be on mobile data.
        return !model.link.isOnline
    }

    private func tint(_ severity: DeviceAction.Severity) -> Color {
        switch severity {
        case .ordinary: return HUD.accent
        case .careful: return HUD.amber
        case .grave: return HUD.alert
        case .good: return HUD.good
        }
    }

    private var footnote: String {
        switch live.kind {
        case .pc:
            return live.wakeable
                ? "Face ID for everything except cancelling. Restart and shut down wait 15 seconds, so Cancel can still stop them. Turning it on is sent by this phone directly, so it works while the PC is off."
                : "Turning it on needs the PC's network card, which it tells this phone the next time you connect at home. Face ID for everything except cancelling."

        case .machine:
            return "Sent by the PC on your behalf, so the PC has to be awake. Nothing here can confirm it worked: a wake packet has no reply, and the machine either comes back or it does not."
        }
    }

    private var spoken: [String] {
        switch live.kind {
        case .pc: return ["Jarvis, lock the PC", "Jarvis, go to sleep", "Jarvis, restart the PC", "Jarvis, shut down the PC", "Jarvis, cancel the shutdown"]
        case .machine: return ["Jarvis, wake \(live.name)", "Jarvis, what machines can you wake?"]
        }
    }
}
