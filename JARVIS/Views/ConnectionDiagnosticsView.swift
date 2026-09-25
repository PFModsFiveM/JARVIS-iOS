import Network
import SwiftUI

/// Why the connection is or is not up, in the order a person would ask it.
///
/// Networking fails quietly and at a distance: an address is tried, nothing answers, and there is
/// nothing to look at. Every line here is a question that was otherwise guessed at - which network
/// is this phone on, which addresses would be tried and in what order, how far the last attempt got,
/// and whether the PC that answered is the PC this phone paired with.
///
/// No key material. The PC's identity is shown as the same short fingerprint both screens show,
/// which is what it is for; nothing here prints a key, a signature or a topic.
struct ConnectionDiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    /// The same browser the model holds, observed here so the candidate list is live rather than
    /// whatever it was when this sheet opened.
    @ObservedObject private var browser = AppModel.shared.browser

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDFrame(title: "Network") {
                    row("This phone", model.onCellular ? "Cellular" : "Wi-Fi or wired")
                    row("Bonjour", browser.found.isEmpty ? "nothing found" : "\(browser.found.count) found")
                    if let problem = browser.problem {
                        Text(problem).font(.footnote).foregroundStyle(HUD.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }

                HUDFrame(title: "Where the PC would be looked for") {
                    if candidates.isEmpty {
                        Text("Nowhere yet. Connect once at home: the PC then tells this phone every address it has, and there is nothing to type.")
                            .font(.footnote).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                        HStack(alignment: .top) {
                            Text("\(index + 1).").font(.system(size: 11, design: .monospaced)).foregroundStyle(HUD.dim)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.describedAs)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(candidate.describedAs == model.route ? HUD.accent : HUD.text)
                                    .textSelection(.enabled)
                                Text(explain(candidate.source)).font(.caption2).foregroundStyle(HUD.dim)
                            }
                        }
                    }
                    Text("Each gets \(String(format: "%.1f", BridgeEndpointResolver.perCandidate)) seconds before the next is tried. An address that cannot be reached from this network does not fail - it waits - so the timeout is what moves on.")
                        .font(.caption).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
                }

                HUDFrame(title: "Connection") {
                    row("State", stateText)
                    row("Using", model.route ?? "-")
                    row("PC identity", model.pc?.fingerprint ?? "-")
                    Text(model.link.isOnline
                         ? "The PC proved it holds the key this phone pinned when it paired. A different PC on the same address would be refused, and the address it answered on makes no difference to that."
                         : "The PC proves its identity during the handshake, on whichever address answered.")
                        .font(.caption).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
                }

                HUDFrame(title: "Waking the PC") {
                    row("Wake-on-LAN", model.wakeProfile.enabled ? "On" : "Off")
                    row("MAC", model.wakeProfile.mac?.description ?? "not known yet")
                    row("From home", model.wakeProfile.broadcast.isEmpty ? "-" : "\(model.wakeProfile.broadcast):\(model.wakeProfile.port)")
                    row("From outside", model.wakeProfile.remoteHost.isEmpty ? "not set" : "\(model.wakeProfile.remoteHost):\(model.wakeProfile.remotePort)")
                    row("From here, now", strategyText)
                    if let last = model.wakeProfile.lastAttempt {
                        row("Last request", last.formatted(date: .abbreviated, time: .standard))
                    }
                    Text("A sent wake request is a request, never a woken PC: the protocol has no reply and UDP is not acknowledged. The PC being awake is established by it answering.")
                        .font(.caption).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
                }

                HUDFrame(title: "Recent attempts") {
                    if model.connectionLog.isEmpty {
                        Text("Nothing yet.").font(.footnote).foregroundStyle(HUD.dim)
                    }
                    ForEach(Array(model.connectionLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(HUD.dim)
                    }
                }
                .textSelection(.enabled)
            }
            .padding(20)
        }
        .background(HUDBackdrop().ignoresSafeArea())
        .navigationTitle("Diagnostics")
    }

    private var candidates: [BridgeCandidate] {
        guard let pc = model.pc else { return [] }
        return BridgeEndpointResolver.candidates(
            for: pc, discovered: browser.found,
            cellular: model.onCellular, preferLocal: pc.preferLocal ?? true)
    }

    private var stateText: String {
        switch model.link {
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .offline(let why): return why ?? "Offline"
        case .unpaired: return "Not paired"
        }
    }

    private var strategyText: String {
        let order = WakeOnLanService.strategies(for: model.wakeProfile, cellular: model.onCellular)
        if order.isEmpty { return model.onCellular ? "nothing set up for outside the house" : "not set up" }
        return order.map { $0 == .localBroadcast ? "home broadcast" : "through the router" }.joined(separator: ", then ")
    }

    private func explain(_ source: BridgeCandidate.Source) -> String {
        switch source {
        case .discovered: return "found on this network - proof the phone is at home"
        case .lastKnownLocal: return "the PC's address on the home network"
        case .privateNetwork: return "private network - works from anywhere"
        case .configured: return "typed in Settings"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            HUDLabel(text: label)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(HUD.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
