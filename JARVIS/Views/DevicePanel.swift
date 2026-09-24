import SwiftUI

/// The PC, whether or not JARVIS is answering.
///
/// The point of this panel is what it does while the bridge is **down**. A PC that is asleep is the
/// case Wake-on-LAN exists for, and an app that can only say "offline" then has a dead page in it
/// exactly when the owner most wants something to press. So: the name, a state a person would
/// recognise, and - when this phone can reach the PC's card from where it is standing - a button.
///
/// One thing it will not say is that the PC is awake because a packet was sent. Wake-on-LAN has no
/// reply and UDP is not acknowledged; "wake request sent" is the whole of what can honestly be
/// claimed, and ONLINE appears when the bridge answers and not a moment before.
struct DevicePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.wakeProfile.deviceName.isEmpty ? model.pcName.uppercased() : model.wakeProfile.deviceName.uppercased())
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(HUD.text)
                    .lineLimit(1)
                Spacer()
                HUDLabel(text: model.device.headline, color: colour)
            }

            Text(model.device.detail)
                .font(.footnote)
                .foregroundStyle(HUD.dim)
                .fixedSize(horizontal: false, vertical: true)

            if model.device.canWake && (model.wakeProfile.usable || model.wakeProfile.reachableRemotely) {
                Button(waking ? "WAKING..." : "WAKE PC") { model.wakePC() }
                    .buttonStyle(HUDButtonStyle())
                    .disabled(waking)
            }

            if case .wakeTimedOut = model.device {
                Button("Try again") { model.dismissWake(); model.wakePC() }
                    .buttonStyle(HUDButtonStyle())
                Text(helpAfterTimeout)
                    .font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let route = model.route, model.device.isOnline {
                Text("via \(route)").font(.caption).foregroundStyle(HUD.dim).lineLimit(1)
            }
        }
    }

    private var waking: Bool {
        switch model.device {
        case .wakeRequested, .waking: return true
        default: return false
        }
    }

    private var colour: Color {
        switch model.device {
        case .online: return HUD.accent
        case .bridgeConnecting, .wakeRequested, .waking: return HUD.dim
        case .wakeTimedOut, .connectionFailed: return HUD.alert
        default: return HUD.amber
        }
    }

    /// What to look at when a wake request went out and nothing came back.
    ///
    /// Written out rather than left as "it didn't work", because every one of these is a real thing
    /// that stops it and none of them is guessable from the phone.
    private var helpAfterTimeout: String {
        model.onCellular
            ? "From mobile data the packet goes to your home connection and your router has to forward it inwards. Check the router still forwards \(model.wakeProfile.remotePort) to \(model.wakeProfile.broadcast.isEmpty ? "the home broadcast address" : model.wakeProfile.broadcast):\(model.wakeProfile.port), and that your home address has not changed."
            : "Check the PC's network card is allowed to wake it (Device Manager › the Ethernet card › Power Management), and that Wake-on-LAN is on in its BIOS. Wake-on-LAN over Wi-Fi usually does not work; this needs the wired card."
    }
}
