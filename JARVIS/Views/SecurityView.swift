import SwiftUI

/// The Security Protocol on the PC, from the phone.
struct SecurityView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmInitiate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDLabel(text: "Security Protocol", color: HUD.accent).padding(.top, 8)

                if model.security?.isChallenge == true {
                    ChallengeBanner()
                }

                HUDFrame(title: "Status", tint: tint) {
                    if let security = model.security {
                        Text(security.description.capitalizedFirst)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint)
                        if security.state == "Enrollment" && security.needed > 0 {
                            ProgressView(value: Double(min(security.learned, security.needed)), total: Double(security.needed))
                                .tint(HUD.accent)
                            Text("Learning how you use the PC: \(security.learned) of \(security.needed).")
                                .font(.footnote).foregroundStyle(HUD.dim)
                        }
                        if let challenge = security.challenge {
                            Text("\(challenge.remaining) s left · \(challenge.attempts) of \(challenge.maxAttempts) attempts\(security.testing ? " · test" : "")")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(HUD.alert)
                        }
                    } else {
                        Text(model.link.isOnline ? "Reading…" : "Not connected to the PC.")
                            .foregroundStyle(HUD.dim)
                    }
                }

                HUDFrame(title: "Control") {
                    Button("Arm") { Task { await model.securityAction("arm") } }
                        .buttonStyle(HUDButtonStyle())
                    Button("Test the challenge") { Task { await model.securityAction("test") } }
                        .buttonStyle(HUDButtonStyle())
                    Text("The red screens on the PC exactly as a stranger would see them. Nothing is locked.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                    Button("Initiate now") { confirmInitiate = true }
                        .buttonStyle(HUDButtonStyle(tint: HUD.amber))
                    Button("Lock the PC") { Task { await model.securityAction("lock") } }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert, filled: true))
                    Button {
                        Task { await model.standDown() }
                    } label: {
                        Label("Stand down", systemImage: "faceid")
                    }
                    .buttonStyle(HUDButtonStyle(tint: HUD.dim))
                    Text("Standing down and answering a challenge need Face ID. The PC checks a signature only this iPhone's Secure Enclave can make after Face ID - a stolen, unlocked phone cannot do it without your face.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                if let toast = model.toast {
                    Text(toast).font(.footnote).foregroundStyle(HUD.amber)
                }
            }
            .padding(20)
        }
        .background(HUD.background.ignoresSafeArea())
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .confirmationDialog("Initiate the Security Protocol now?", isPresented: $confirmInitiate, titleVisibility: .visible) {
            Button("Initiate", role: .destructive) { Task { await model.securityAction("initiate") } }
        } message: {
            Text("The red screens come up on the PC. If the password isn't entered in time, Windows is locked.")
        }
    }

    private var tint: Color {
        guard let security = model.security else { return HUD.dim }
        if security.isChallenge { return HUD.alert }
        if security.isOff { return HUD.dim }
        return security.state == "Armed" ? HUD.good : HUD.accent
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
