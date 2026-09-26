import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var wakeMac = ""
    @State private var wakeBroadcast = ""
    @State private var wakeCardProblem: String?
    @State private var confirmForget = false
    @State private var showingDiagnostics = false
    @State private var selfTest: [(name: String, passed: Bool)] = []
    @State private var remoteHost = AppModel.shared.pc?.remoteHost ?? ""
    @State private var wakeHost = AppModel.shared.wakeProfile.remoteHost
    @State private var wakePort = String(AppModel.shared.wakeProfile.remotePort)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HUDLabel(text: "Settings", color: HUD.accent).padding(.top, 8)

                // Grouped, and not for tidiness: a VStack takes ten children and this one is full,
                // so the eleventh would not compile. Two panels about the same machine are the
                // right two to fold together.
                Group {
                    HUDFrame(title: "PC") {
                        row("Name", model.pcName)
                        row("Version", model.status["version"] as? String ?? "-")
                        row("Key", model.pc?.fingerprint ?? "-")
                        Text("The key must match the one on the PC's Settings › iPhone page.")
                            .font(.footnote).foregroundStyle(HUD.dim)
                        Button("Reconnect") { Task { await model.disconnect(); await model.connect() } }
                            .buttonStyle(HUDButtonStyle())
                    }

                    BeforeSignInPanel()
                }

                HUDFrame(title: "Waking \(model.wakeProfile.deviceName)") {
                    Toggle("Wake-on-LAN", isOn: Binding(get: { model.wakeProfile.enabled }, set: { model.setWakeEnabled($0) }))
                        .tint(HUD.accent).foregroundStyle(HUD.text)

                    if let mac = model.wakeProfile.mac {
                        row("MAC", mac.description)
                        row("From home", "\(model.wakeProfile.broadcast):\(model.wakeProfile.port)")

                        if model.wakeProfile.typedByHand == true {
                            Text("Typed by hand, and kept: connecting to the PC will not overwrite it.")
                                .font(.footnote).foregroundStyle(HUD.dim)
                        }
                    } else {
                        Text("Connect to the PC once at home and it tells this phone its card's address and the home network's broadcast address - there is nothing to type.")
                            .font(.footnote).foregroundStyle(HUD.dim)

                        // The one case the learnt-from-the-PC route cannot cover: a PC that has been
                        // off ever since the app was installed. The phone has nothing to connect to,
                        // so it never learns the card, so the button to switch the PC on is the one
                        // button that is unavailable - for exactly the machine somebody wants on.
                        Text("If it has been off the whole time, type them instead. Both are on the PC's own `SpeechDiag network` screen, and on your router's page.")
                            .font(.footnote).foregroundStyle(HUD.dim).padding(.top, 4)

                        field("Card address (04-7C-16-4E-A7-F5)", text: $wakeMac, keyboard: .asciiCapable)
                        field("Home broadcast address (192.168.1.255)", text: $wakeBroadcast, keyboard: .numbersAndPunctuation)

                        Button("Save the card") {
                            wakeCardProblem = model.setWakeCard(mac: wakeMac, broadcast: wakeBroadcast)
                        }
                        .buttonStyle(HUDButtonStyle())

                        if let problem = wakeCardProblem {
                            Text(problem).font(.footnote).foregroundStyle(HUD.alert)
                        }
                    }

                    Text("From outside the house").font(.footnote).foregroundStyle(HUD.dim).padding(.top, 4)
                    field("Remote wake host (a DDNS name, or your home IP)", text: $wakeHost, keyboard: .URL)
                    field("Remote wake port", text: $wakePort, keyboard: .numberPad)
                    Toggle("Allow waking over mobile data", isOn: Binding(get: { model.wakeProfile.overCellular }, set: { model.setWakeOverCellular($0) }))
                        .tint(HUD.accent).foregroundStyle(HUD.text)
                    Button("Save") { model.setWakeRemote(host: wakeHost, port: UInt16(wakePort)) }
                        .buttonStyle(HUDButtonStyle())

                    Text("Your router has to forward that port to \(model.wakeProfile.broadcast.isEmpty ? "your home network's broadcast address" : model.wakeProfile.broadcast) on UDP \(model.wakeProfile.port). Use a dynamic-DNS name rather than your home IP address, which your provider will change. A wake request proves nothing about who sent it - the protocol has no secret in it - so the only thing that port can ever do is switch the PC on.")
                        .font(.footnote).foregroundStyle(HUD.dim)

                    if let last = model.wakeProfile.lastAttempt {
                        Text("Last wake request: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(HUD.dim)
                    }
                }

                HUDFrame(title: "Away from home") {
                    HStack {
                        HUDLabel(text: "Connected")
                        Spacer()
                        Text(model.route ?? "-").font(.system(.body, design: .monospaced)).foregroundStyle(HUD.text)
                    }
                    Toggle("Prefer the home network when it is there", isOn: Binding(get: { model.pc?.preferLocal ?? true }, set: { model.setPreferLocal($0) }))
                        .tint(HUD.accent).foregroundStyle(HUD.text)

                    if let known = model.pc?.remoteHosts, !known.isEmpty {
                        Text("The PC has told this phone where else to find it:").font(.footnote).foregroundStyle(HUD.dim)
                        ForEach(known, id: \.self) { host in
                            Text(host).font(.system(size: 11, design: .monospaced)).foregroundStyle(HUD.text).textSelection(.enabled)
                        }
                    }

                    field("Another address for the PC (optional)", text: $remoteHost, keyboard: .URL)
                        .onSubmit { model.setRemoteHost(remoteHost) }
                    Button("Save") {
                        model.setRemoteHost(remoteHost)
                        Task { await model.disconnect(); await model.connect() }
                    }
                    .buttonStyle(HUDButtonStyle())
                    Button("Connection diagnostics") { showingDiagnostics = true }
                        .buttonStyle(HUDButtonStyle())
                    if !model.connectionLog.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.connectionLog.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(HUD.dim)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    Text("To use JARVIS on mobile data: install Tailscale on the PC and on this iPhone and sign in to the same account on both. Connect to the PC once at home after that and it tells this phone where to find it - there is nothing to type. Everything stays encrypted end to end exactly as it is at home; Tailscale only carries it, and the PC still has to prove it is the PC this phone paired with.")
                        .font(.footnote).foregroundStyle(HUD.dim)
                }

                WhereaboutsSection(reporter: model.whereabouts)

                LearningSection(learning: LearningModel.shared)

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
        .background(HUDBackdrop().ignoresSafeArea())
        .sheet(isPresented: $showingDiagnostics) { ConnectionDiagnosticsView() }
        .confirmationDialog("Forget this PC?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await model.forget() } }
        }
    }

    /// A text box in the HUD's own style, so the several on this page look like one thing.
    private func field(_ prompt: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .foregroundStyle(HUD.text)
            .padding(9)
            .background(HUD.background)
            .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            HUDLabel(text: label)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(HUD.text).lineLimit(1)
        }
    }
}

/// Where you are, and whether the PC is being told.
///
/// Its own view watching its own object, rather than reading the reporter through the app model.
/// A view redraws for the objects it observes, and the reporter is not the app model: granting the
/// permission would have left this toggle showing off until the screen was left and come back to.
/// Elsewhere this codebase mirrors nested state onto the app model for the same reason - that is
/// right for one value, and four would be four things to keep in step.
struct WhereaboutsSection: View {
    @ObservedObject var reporter: LocationReporter

    var body: some View {
        HUDFrame(title: "Where you are") {
            Toggle("Tell the PC where I am", isOn: Binding(
                get: { reporter.reporting },
                set: { on in on ? reporter.start() : reporter.stop() }))
                .tint(HUD.accent).foregroundStyle(HUD.text)

            if reporter.reporting {
                HStack {
                    Text(reporter.lastReported.map { "Last sent \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "Nothing sent yet")
                    Spacer()
                    if reporter.waiting > 0 {
                        Text("\(reporter.waiting) waiting")
                    }
                }
                .font(.footnote).foregroundStyle(HUD.dim)
            } else if !reporter.authorised {
                Text("iOS will ask for location, and then ask again a little later whether JARVIS may have it all the time. The second one is the one that matters: without it JARVIS only knows where you are while this app is open.")
                    .font(.footnote).foregroundStyle(HUD.dim)
            }

            Text("Your positions go to your own PC and nowhere else. iOS wakes JARVIS when you move a few hundred metres rather than tracking you continuously, which is why this costs almost no battery. Anything recorded while the PC is off waits on this phone and is sent when it comes back.")
                .font(.footnote).foregroundStyle(HUD.dim)
        }
    }
}

/// The PC's learning session: start it, stop it, and watch it go by the PC's own counts.
struct LearningSection: View {
    @ObservedObject var learning: LearningModel

    var body: some View {
        HUDFrame(title: "Learning") {
            Text(learning.status.said)
                .font(.footnote).foregroundStyle(HUD.text)

            if learning.status.running {
                HStack {
                    HUDLabel(text: "Step \(learning.status.step) of \(learning.status.steps)")
                    Spacer()
                    if learning.status.of > 0 {
                        Text("\(learning.status.done) of \(learning.status.of)")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(HUD.dim)
                    }
                }
                if let fraction = learning.status.stepFraction {
                    ProgressView(value: fraction).tint(HUD.accent)
                }
                Button("Stop") { Task { await learning.stop() } }
                    .buttonStyle(HUDButtonStyle())
            } else {
                Button("Start a learning session") { Task { await learning.start() } }
                    .buttonStyle(HUDButtonStyle())
            }

            if let message = learning.message {
                Text(message).font(.caption).foregroundStyle(HUD.dim)
            }

            Text("JARVIS on your PC goes over how it has been used - what it got wrong, what you corrected, how long things took - and learns from it. Only small, reversible things are ever changed on their own; anything bigger is left for you. The same session can be started from the PC by saying \"start a learning session\".")
                .font(.footnote).foregroundStyle(HUD.dim)
        }
        .task { await learning.refresh() }
    }
}
