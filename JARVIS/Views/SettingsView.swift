import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmForget = false
    @State private var selfTest: [(name: String, passed: Bool)] = []

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
