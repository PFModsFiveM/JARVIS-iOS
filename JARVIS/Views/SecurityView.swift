import SwiftUI

/// The Security Protocol on the PC, from the phone.
struct SecurityView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmInitiate = false
    @State private var showRecordings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDLabel(text: "Security Protocol", color: HUD.accent).padding(.top, 8)

                if model.security?.isChallenge == true {
                    ChallengeBanner()
                }

                if let photo = model.challengePhoto {
                    HUDFrame(title: "Who was at the PC", tint: HUD.alert) {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .overlay(alignment: .topTrailing) {
                                // On the picture rather than under it. Whoever wants this gone is
                                // looking at the picture, and a button below the caption is one
                                // scroll away from where their eyes already are.
                                Button {
                                    withAnimation { model.dismissChallengePhoto() }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(HUD.alert)
                                        .padding(8)
                                        .background(.black.opacity(0.55), in: Circle())
                                }
                                .padding(8)
                                .accessibilityLabel("Dismiss the picture")
                            }

                        Text("Taken by the PC's camera when the Security Protocol challenged them.")
                            .font(.footnote).foregroundStyle(HUD.dim)

                        Button("Dismiss") { withAnimation { model.dismissChallengePhoto() } }
                            .buttonStyle(HUDButtonStyle())
                    }
                    .transition(.opacity)
                }

                // What the camera kept, one level down rather than as a sixth tab. It is looked at
                // occasionally and after the fact, which is not worth a permanent place along the
                // bottom of the screen.
                HUDFrame(title: "Recordings") {
                    Button("What the camera kept") { showRecordings = true }
                        .buttonStyle(HUDButtonStyle())

                    Text("Incidents from the last week, with the screen and the camera.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                // The room as it is now, next to what the camera kept - the two questions somebody
                // asks when their phone buzzes, one after the other.
                HUDFrame(title: "The room, live") {
                    if let frame = model.cameraFrame {
                        Image(uiImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if model.watchingCamera {
                        if model.cameraFrame == nil {
                            Text("Waiting for a frame…").font(.footnote).foregroundStyle(HUD.dim)
                        }

                        Button("Stop watching") { Task { await model.stopWatchingCamera() } }
                            .buttonStyle(HUDButtonStyle())
                    } else {
                        Button("Watch the camera") { Task { await model.startWatchingCamera() } }
                            .buttonStyle(HUDButtonStyle())

                        // Said before it is tried, because the refusal is the common case and it
                        // is not a fault: the camera runs when security mode or the PC's own
                        // camera panel is on, and watching from here never switches it on.
                        Text("Shows what the camera is already seeing. It won't switch the camera on.")
                            .font(.footnote).foregroundStyle(HUD.dim)
                    }
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
                    // Both in the one alert red, outlined: these are the two buttons that do something to
                    // the PC that cannot be waved away, and a solid slab of colour was louder than either.
                    Button("Initiate now") { confirmInitiate = true }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert))
                    Button("Lock the PC") { Task { await model.securityAction("lock") } }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert))
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
        .background(HUDBackdrop().ignoresSafeArea())
        .refreshable { await model.refresh() }
        .task { await model.refresh() }

        // Leaving the tab stops the stream. Frames are a few tens of kilobytes each and somebody
        // who switched away is not watching; charging them for it until they notice would be the
        // sort of thing you only find on next month's bill.
        .onDisappear { Task { await model.stopWatchingCamera() } }
        .confirmationDialog("Initiate the Security Protocol now?", isPresented: $confirmInitiate, titleVisibility: .visible) {
            Button("Initiate", role: .destructive) { Task { await model.securityAction("initiate") } }
        } message: {
            Text("The red screens come up on the PC. If the password isn't entered in time, Windows is locked.")
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView()
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
