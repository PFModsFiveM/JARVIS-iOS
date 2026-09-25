import SwiftUI

/// The smart-home devices on the Home tab: one tile per device, grouped by room.
///
/// Every tile switches the device through the PC - never through a vendor - and draws whatever the
/// PC says afterwards, including a change made on the PC itself or by voice, which arrives as a push.
/// Two buttons rather than a toggle: the Bedroom Light's Bot is on a rocker in switch mode, and a
/// toggle whose current state is unknown cannot say what pressing it will do. ON always means on.
struct SmartHomePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var home = SmartHomeModel.shared

    var body: some View {
        if !home.devices.isEmpty {
            HUDFrame(title: "Smart home") {
                ForEach(home.rooms) { room in
                    VStack(alignment: .leading, spacing: 10) {
                        HUDLabel(text: room.room, color: HUD.accentDeep)
                        ForEach(room.devices) { device in
                            NavigationLink { SmartDeviceView(id: device.id) } label: {
                                SmartDeviceTile(device: device, message: home.messages[device.id], reachable: model.link.isOnline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if home.simulating {
                    HUDLabel(text: "Simulation - nothing in the house moves", color: HUD.amber)
                }

                if !model.link.isOnline {
                    Text("Switched through your PC, which isn't answering. Wake it, or wait for it to reconnect.")
                        .font(.footnote)
                        .foregroundStyle(HUD.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One device: a glyph that lights with it, its name and state, and the two-position switch.
struct SmartDeviceTile: View {
    let device: SmartDevice
    let message: String?
    let reachable: Bool

    @ObservedObject private var home = SmartHomeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                DeviceGlyph(lit: device.shown == .on, busy: device.shown == .updating, faulted: faulted)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(device.shown == .on ? HUD.bright : HUD.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(message != nil || faulted ? HUD.amber : HUD.dim)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                HUDLabel(text: word, color: tint)
                    .lineLimit(1)
                    .fixedSize()
            }

            if device.canSwitch {
                PowerSwitch(device: device, enabled: reachable && device.shown != .updating) { on in
                    Task { await home.setPower(device, on: on) }
                }
            }
        }
        .padding(12)
        .background(device.shown == .on ? HUD.accent.opacity(0.07) : HUD.background.opacity(0.35))
        .overlay(Rectangle().stroke((device.shown == .on ? HUD.accent : HUD.line).opacity(device.shown == .on ? 0.55 : 1), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var faulted: Bool { device.shown == .offline || device.shown == .error }

    private var word: String {
        switch device.shown {
        case .on: return "On"
        case .off: return "Off"
        case .updating: return "Updating"
        case .offline: return "Offline"
        case .error: return "Error"
        case .notSetUp: return "Not set up"
        case .unknown: return "Unknown"
        }
    }

    private var tint: Color {
        switch device.shown {
        case .on: return HUD.bright
        case .updating: return HUD.accent
        case .offline, .error: return HUD.amber
        default: return HUD.dim
        }
    }

    private var detail: String {
        if let message { return message }
        if let problem = device.problem { return problem.replacingOccurrences(of: ", sir", with: "") }
        if !device.bound { return "Not set up - assign it on the PC" }

        var parts: [String] = []
        switch device.certainty {
        case .confirmed: parts.append(device.readAt.map { "Confirmed \(Self.ago($0))" } ?? "Confirmed")
        case .assumed: parts.append("Sent - not yet confirmed")
        case .unknown: parts.append("State unknown")
        }
        if let battery = device.battery { parts.append("\(battery)%") }
        if device.simulated { parts.append("Simulated") }
        return parts.joined(separator: "  ·  ")
    }

    static func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}

/// ON and OFF side by side. The lit side is what the device is believed to be doing.
struct PowerSwitch: View {
    let device: SmartDevice
    let enabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: -1) {
                side("On", lit: device.shown == .on) { set(true) }
                side("Off", lit: device.shown == .off) { set(false) }
            }

            // A thin sweep while the command is out, so a slow hub reads as working rather than stuck.
            if device.shown == .updating {
                Sweep().frame(height: 2)
            }
        }
        .disabled(!enabled)
    }

    /// One side. While the switch can be used, the side matching the state is solid light with dark
    /// type. While it cannot - the PC is away, or a command is out - the state still has to be readable,
    /// so the lit side keeps bright type on a faint wash and only the other side fades back.
    private func side(_ label: String, lit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(HUD.spaced(label))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(lit ? (enabled ? HUD.background : HUD.bright) : HUD.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(lit ? (enabled ? HUD.accent : HUD.accent.opacity(0.18)) : HUD.accent.opacity(0.05))
                .overlay(Rectangle().stroke(HUD.accent.opacity(lit ? (enabled ? 1 : 0.6) : 0.35), lineWidth: 1))
                .shadow(color: lit && enabled ? HUD.accent.opacity(0.55) : .clear, radius: 8)
                .opacity(lit || enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.name) \(label)")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// A moving bar, for work in progress that has no percentage.
struct Sweep: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(HUD.accent)
                .frame(width: geometry.size.width * 0.25)
                .offset(x: geometry.size.width * phase)
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1.05 }
        }
    }
}

/// The device's glyph: a bulb in a ring that lights when it is on, pulses while a command is out.
struct DeviceGlyph: View {
    let lit: Bool
    let busy: Bool
    var faulted = false

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(HUD.line, lineWidth: 1)
            Circle()
                .trim(from: 0, to: busy ? 0.3 : (lit ? 1 : 0))
                .stroke(faulted ? HUD.amber : HUD.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(busy && spin ? 360 : -90))
                .shadow(color: lit ? HUD.accent.opacity(0.8) : .clear, radius: 6)
            Image(systemName: lit ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(lit ? HUD.bright : (faulted ? HUD.amber : HUD.dim))
                .shadow(color: lit ? HUD.accent : .clear, radius: 10)
        }
        .onAppear {
            guard busy else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// One device's own page: the state large, what is known about it, and every way to switch it.
struct SmartDeviceView: View {
    let id: String

    @EnvironmentObject var model: AppModel
    @ObservedObject private var home = SmartHomeModel.shared

    private var device: SmartDevice? { home.devices.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let device {
                VStack(spacing: 16) {
                    VStack(spacing: 14) {
                        DeviceGlyph(lit: device.shown == .on, busy: device.shown == .updating,
                                    faulted: device.shown == .offline || device.shown == .error)
                            .frame(width: 120, height: 120)
                            .padding(.top, 8)

                        Text(HUD.spaced(device.statusText.isEmpty ? device.shown.rawValue : device.statusText))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(device.shown == .on ? HUD.bright : HUD.dim)

                        if let problem = home.messages[device.id] ?? device.problem {
                            Text(problem.replacingOccurrences(of: ", sir", with: ""))
                                .font(.footnote)
                                .foregroundStyle(HUD.amber)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if device.canSwitch {
                        HUDFrame(title: "Power") {
                            PowerSwitch(device: device, enabled: model.link.isOnline && device.shown != .updating) { on in
                                Task { await home.setPower(device, on: on) }
                            }

                            if device.capabilities.contains("press") {
                                Button("Single press") { Task { await home.press(device) } }
                                    .buttonStyle(HUDButtonStyle())
                                    .disabled(!model.link.isOnline || device.shown == .updating)
                            }
                        }
                    }

                    HUDFrame(title: "Readout") {
                        Readout(label: "Room", value: device.room ?? "-")
                        Readout(label: "State", value: device.statusText.isEmpty ? device.shown.rawValue : device.statusText)
                        Readout(label: "Certainty", value: certainty(device))
                        Readout(label: "Last read", value: device.readAt.map(SmartDeviceTile.ago) ?? "Never")
                        if let battery = device.battery { Readout(label: "Battery", value: "\(battery)%") }
                        Readout(label: "Last command", value: lastCommand(device))
                        Readout(label: "Reached via", value: device.simulated ? "Your PC (simulation)" : "Your PC")

                        Button("Read it now") { Task { await home.refresh(device.id) } }
                            .buttonStyle(HUDButtonStyle())
                            .disabled(!model.link.isOnline)
                    }

                    if !device.bound {
                        HUDFrame(title: "Set up") {
                            Text("Nothing is assigned to \(device.name) yet. When the hardware is paired in the SwitchBot app, open JARVIS on the PC › Settings › Smart Home, discover devices and assign the Bot. The phone never needs the SwitchBot password or keys.")
                                .font(.footnote)
                                .foregroundStyle(HUD.dim)
                        }
                    }

                    HUDFrame(title: "Say it instead") {
                        ForEach(["Jarvis, turn the \(device.name.lowercased()) on", "Jarvis, lights out", "Jarvis, is the \(device.name.lowercased()) on?"], id: \.self) { line in
                            Text("\u{201C}\(line)\u{201D}").font(.footnote).foregroundStyle(HUD.dim)
                        }
                    }
                }
                .padding(16)
            } else {
                Text("That device is no longer on the PC.")
                    .foregroundStyle(HUD.dim)
                    .padding(.top, 60)
            }
        }
        .hudScreen()
        .hudTitle(device?.name ?? "Device")
        .refreshable { await home.refresh(id) }
        .task { await home.refresh(id) }
    }

    private func certainty(_ device: SmartDevice) -> String {
        switch device.certainty {
        case .confirmed: return "Reported by the device"
        case .assumed: return "Command accepted, not yet read back"
        case .unknown: return "Unknown"
        }
    }

    private func lastCommand(_ device: SmartDevice) -> String {
        guard let command = device.lastCommand else { return "None yet" }
        let what = ["powerOn": "On", "powerOff": "Off", "press": "Press"][command] ?? command
        let outcome = device.lastResult == "accepted" ? "accepted" : (device.lastResult ?? "")
        return outcome.isEmpty ? what : "\(what) - \(outcome)"
    }
}

/// A label and a value on one line, in the HUD's type.
struct Readout: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HUDLabel(text: label)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(HUD.text)
                .multilineTextAlignment(.trailing)
        }
    }
}
