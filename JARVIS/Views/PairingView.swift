import Network
import SwiftUI

/// First run: find the PC, type the code it shows, compare six digits, and say yes on the PC.
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var browser = PCBrowser()

    @State private var chosen: FoundPC?
    @State private var manualHost = ""
    @State private var manualPort = "47823"
    @State private var code = ""
    @State private var pairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("J.A.R.V.I.S")
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                    .kerning(6)
                    .foregroundStyle(HUD.accent)
                    .padding(.top, 24)
                HUDLabel(text: "Pair with your PC")

                HUDFrame(title: "1  On the PC") {
                    Text("Open JARVIS › Settings › iPhone, switch on \u{201C}Let the iPhone app connect\u{201D} and press Pair an iPhone. Keep this phone on the same Wi-Fi.")
                        .foregroundStyle(HUD.text)
                }

                HUDFrame(title: "2  Choose the PC") {
                    if browser.found.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(HUD.accent)
                            Text("Looking on this Wi-Fi…").foregroundStyle(HUD.dim)
                        }
                    }
                    ForEach(browser.found) { pc in
                        Button {
                            chosen = pc
                            manualHost = ""
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(pc.name).lineLimit(1)
                                Spacer()
                                if chosen == pc && manualHost.isEmpty { Image(systemName: "checkmark") }
                            }
                            .foregroundStyle(chosen == pc && manualHost.isEmpty ? HUD.accent : HUD.text)
                            .padding(.vertical, 6)
                        }
                    }
                    if let problem = browser.problem {
                        Text(problem).font(.footnote).foregroundStyle(HUD.amber)
                    }
                    DisclosureGroup("Type the address instead") {
                        HStack {
                            TextField("192.168.1.20", text: $manualHost)
                                .keyboardType(.decimalPad)
                            TextField("port", text: $manualPort)
                                .keyboardType(.numberPad)
                                .frame(width: 70)
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 6)
                        Text("The PC's Settings › iPhone page shows its address.").font(.footnote).foregroundStyle(HUD.dim)
                    }
                    .tint(HUD.accent)
                    .foregroundStyle(HUD.text)
                }

                HUDFrame(title: "3  Code") {
                    TextField("ABC234", text: $code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(HUD.accent)
                        .onChange(of: code) { _, value in code = String(value.uppercased().prefix(6)) }
                }

                if let digits = model.pairingDigits {
                    HUDFrame(title: "4  Compare", tint: HUD.amber) {
                        Text("The PC should show exactly these digits. If it does, press \u{201C}They match\u{201D} on the PC. If not, press Decline there - something is between this phone and your PC.")
                            .foregroundStyle(HUD.text)
                        Text("\(digits.prefix(3)) \(digits.suffix(3))")
                            .font(.system(size: 44, weight: .heavy, design: .monospaced))
                            .foregroundStyle(HUD.amber)
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    Task { await pair() }
                } label: {
                    HStack {
                        if pairing { ProgressView().tint(HUD.background) }
                        Text(pairing ? "Waiting for the PC" : "Pair")
                    }
                }
                .buttonStyle(HUDButtonStyle(filled: true))
                .disabled(pairing || code.count != 6 || (chosen == nil && manualHost.isEmpty))
                .opacity(pairing || code.count != 6 || (chosen == nil && manualHost.isEmpty) ? 0.5 : 1)

                if let toast = model.toast {
                    Text(toast).font(.footnote).foregroundStyle(HUD.amber)
                }
            }
            .padding(20)
        }
        .background(HUD.background.ignoresSafeArea())
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        model.toast = nil

        if !manualHost.isEmpty {
            let port = UInt16(manualPort) ?? 47823
            await model.pair(endpoint: .hostPort(host: NWEndpoint.Host(manualHost), port: NWEndpoint.Port(rawValue: port) ?? 47823),
                             serviceName: nil, host: manualHost, port: port, code: code)
        } else if let chosen {
            await model.pair(endpoint: chosen.endpoint, serviceName: chosen.name, host: nil, port: 47823, code: code)
        }
    }
}
