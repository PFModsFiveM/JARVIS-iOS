import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmForget = false
    @State private var selfTest: [(name: String, passed: Bool)] = []
    @State private var remoteHost = AppModel.shared.pc?.remoteHost ?? ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDLabel(text: "Settings", color: HUD.accent).padding(.top, 8)

                HUDFrame(title: "PC") {
                    row("Name", model.pcName)
                    row("Version", model.status["version"] as? String ?? "-")
                    row("Key", model.pc?.fingerprint ?? "-")
                    Text("The key must match the one on the PC's Settings › iPhone page.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                    Button("Reconnect") { Task { await model.disconnect(); await model.connect() } }
                        .buttonStyle(HUDButtonStyle())
                }

                HUDFrame(title: "Away from home") {
                    HStack {
                        HUDLabel(text: "Connected")
                        Spacer()
                        Text(model.route ?? "-").font(.system(.body, design: .monospaced)).foregroundStyle(HUD.text)
                    }
                    TextField("PC's Tailscale address (100.x.y.z)", text: $remoteHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .foregroundStyle(HUD.text)
                        .padding(9)
                        .background(HUD.background)
                        .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
                        .onSubmit { model.setRemoteHost(remoteHost) }
                    Button("Save") {
                        model.setRemoteHost(remoteHost)
                        Task { await model.disconnect(); await model.connect() }
                    }
                    .buttonStyle(HUDButtonStyle())
                    Text("To use JARVIS on mobile data: install Tailscale on the PC and on this iPhone, sign in to the same account on both, and type the PC's Tailscale address here (it is shown in JARVIS › Settings › iPhone). Everything stays encrypted end to end as it is at home; Tailscale only carries it.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                HUDFrame(title: "Alerts when JARVIS is closed") {
                    Toggle("Send alerts through ntfy", isOn: Binding(get: { model.alertsTopic != nil }, set: { on in Task { await model.setAlerts(on) } }))
                        .tint(HUD.accent).foregroundStyle(HUD.text)
                    if let topic = model.alertsTopic {
                        HStack {
                            Text(topic).font(.system(.footnote, design: .monospaced)).foregroundStyle(HUD.text).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = topic
                                model.toast = "Topic copied."
                            }
                            .font(.footnote)
                        }
                        Link("Get the ntfy app", destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!)
                            .font(.footnote)
                        Text("In ntfy, tap + and paste this topic (server ntfy.sh). Security challenges, reminders and JARVIS's announcements then arrive even with this app closed or away from home. Only the short alert text goes through ntfy - never photos, your screen or files. Turn this off and on again for a new topic.")
                            .font(.footnote).foregroundStyle(HUD.dim)
                    } else {
                        Text("Off. JARVIS's alerts reach this iPhone only while the app is open (or listening in the background).")
                            .font(.footnote).foregroundStyle(HUD.dim)
                    }
                }

                HUDFrame(title: "Display") {
                    Picker("Centrepiece", selection: $model.centrepiece) {
                        ForEach(Centrepiece.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Facial expressions", isOn: $model.facialState)
                        .tint(HUD.accent).foregroundStyle(HUD.text)
                    Text("The circle and the face both follow what JARVIS is doing: listening, thinking, speaking, and red for a security challenge. Tap it on the home screen to switch. With expressions off the face stays neutral but its lips still move.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                HUDFrame(title: "Voice") {
                    Toggle("Speak answers", isOn: $model.speakAnswers)
                        .tint(HUD.accent).foregroundStyle(HUD.text)
                    Toggle("JARVIS's own voice", isOn: $model.usePCVoice)
                        .tint(HUD.accent).foregroundStyle(HUD.text)
                    Text("Answers are spoken in the same voice as on your PC, sent from it with each answer. Off, or if it doesn't arrive, the iPhone reads them out itself.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                    Text("Wake word: on-device recognition only; nothing is sent until you say \u{201C}Jarvis\u{201D} and a request. For the best voice, download an English (UK) Enhanced or Premium voice in iOS Settings › Accessibility › Spoken Content › Voices.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                HUDFrame(title: "Siri and the Action button") {
                    Text("\u{201C}Hey Siri, ask JARVIS\u{201D}, \u{201C}Hey Siri, lock my PC with JARVIS\u{201D} and \u{201C}JARVIS security status\u{201D} work straight away. In Settings › Action Button › Shortcut, choose JARVIS › Ask JARVIS.")
                        .font(.footnote).foregroundStyle(HUD.text)
                }

                HUDFrame(title: "Encryption self-test") {
                    Button("Run") { selfTest = BridgeSelfTest.run() }
                        .buttonStyle(HUDButtonStyle())
                    ForEach(selfTest.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: selfTest[index].passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(selfTest[index].passed ? HUD.good : HUD.alert)
                            Text(selfTest[index].name).foregroundStyle(HUD.text)
                        }
                    }
                    Text("Checks this iPhone computes the same keys, digits and frames as the PC.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                HUDFrame(title: "Forget", tint: HUD.alert) {
                    Button("Forget this PC") { confirmForget = true }
                        .buttonStyle(HUDButtonStyle(tint: HUD.alert))
                    Text("Deletes this phone's keys. Also press Forget next to this iPhone on the PC.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }
            }
            .padding(20)
        }
        .background(HUD.background.ignoresSafeArea())
        .confirmationDialog("Forget this PC?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await model.forget() } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            HUDLabel(text: label)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(HUD.text).lineLimit(1)
        }
    }
}
