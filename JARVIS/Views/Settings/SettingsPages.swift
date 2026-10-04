import SwiftUI
import UIKit

/// The page behind one row of Settings.
///
/// One switch, in one place, so `SettingsDestination` and the thing it opens cannot drift apart -
/// and so a deep link, a search result and a tap on the list all arrive at the same view.
struct SettingsPage: View {
    let destination: SettingsDestination

    var body: some View {
        Group {
            switch destination {
            case .connection: ConnectionPage()
            case .appearance: AppearancePage()
            case .voice: VoicePage()
            case .siri: SiriPage()
            case .alerts: AlertsPage()
            case .mobileCapabilities: MobileCapabilitiesPage()
            case .standbyLights: StandbyLightsPage()
            case .whereabouts: WhereaboutsPage()
            case .waking: WakingPage()
            case .reaching: ReachingPage()
            case .smartHome: SmartHomePage()
            case .power: PowerPage()
            case .footageStore: FootageStorePage()
            case .learning: LearningPage()
            case .diagnostics: DiagnosticsPage()
            case .encryption: EncryptionPage()
            case .forget: ForgetPage()
            case .about: AboutPage()
            }
        }
        .hudTitle(SettingsCatalogue.entry(for: destination)?.title ?? "Settings")
    }
}

// MARK: - General

private struct ConnectionPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ValueRow(title: "Name", value: model.pcName, monospaced: false)
                ValueRow(title: "Version", value: model.status["version"] as? String ?? "-")
                StatusRow(title: "Link", status: linkStatus)
                if let fingerprint = model.pc?.fingerprint {
                    CopyableValue(title: "Key", value: fingerprint, toast: "Key copied.")
                }
                ActionRow(title: "Reconnect", symbol: "arrow.clockwise") {
                    Task { await model.disconnect(); await model.connect() }
                }
            } header: {
                HUDSectionTitle(text: "This PC")
            } footer: {
                SettingsNote("The key must match the one on the PC's Settings \u{203A} iPhone page.")
            }

            Section {
                BeforeSignInPanel()
                    .hudPanelRow()
            } header: {
                HUDSectionTitle(text: "Before anyone signs in")
            }
        }
        .hudList()
    }

    /// §21, on the row where the distinction matters most: paired is not connected.
    private var linkStatus: SettingsStatus {
        switch model.link {
        case .online(let name): return .live(name)
        case .connecting: return .ready("Connecting")
        case .offline(let why): return .configured(why ?? "Not answering")
        case .unpaired: return .off("Not paired")
        }
    }
}

private struct AppearancePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                Picker("Centrepiece", selection: $model.centrepiece) {
                    ForEach(Centrepiece.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .hudRow()

                ToggleRow(title: "Facial expressions", isOn: $model.facialState)
            } footer: {
                SettingsNote("The circle and the face both follow what JARVIS is doing: listening, thinking, speaking, and red for a security challenge. Tap it on the home screen to switch. With expressions off the face stays neutral but its lips still move.")
            }
        }
        .hudList()
    }
}

private struct VoicePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ToggleRow(title: "Speak answers", isOn: $model.speakAnswers)
                ToggleRow(title: "JARVIS's own voice", isOn: $model.usePCVoice)
            } header: {
                HUDSectionTitle(text: "Answers")
            } footer: {
                SettingsNote("Answers are spoken in the same voice as on your PC, sent from it with each answer. Off, or if it doesn't arrive, the iPhone reads them out itself.")
            }

            Section {
                StatusRow(title: "Wake word", status: model.wakeWordOn ? .live("Listening") : .off("Off"))
            } header: {
                HUDSectionTitle(text: "Listening")
            } footer: {
                SettingsNote("On-device recognition only; nothing is sent until you say \u{201C}Jarvis\u{201D} and a request. Turn it on from the JARVIS screen.\n\nFor the best voice, download an English (UK) Enhanced or Premium voice in iOS Settings \u{203A} Accessibility \u{203A} Spoken Content \u{203A} Voices.")
            }
        }
        .hudList()
    }
}

private struct SiriPage: View {
    var body: some View {
        List {
            Section {
                SettingsNote("\u{201C}Hey Siri, ask JARVIS\u{201D}, \u{201C}Hey Siri, lock my PC with JARVIS\u{201D} and \u{201C}JARVIS security status\u{201D} work straight away.")
                    .hudRow()
                SettingsNote("In Settings \u{203A} Action Button \u{203A} Shortcut, choose JARVIS \u{203A} Ask JARVIS.")
                    .hudRow()
            }
        }
        .hudList()
    }
}

private struct AlertsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ToggleRow(title: "Send alerts through ntfy",
                          isOn: Binding(get: { model.alertsTopic != nil },
                                        set: { on in Task { await model.setAlerts(on) } }))
                if let topic = model.alertsTopic {
                    CopyableValue(title: "Topic", value: topic, toast: "Topic copied.")
                }
            } header: {
                HUDSectionTitle(text: "While JARVIS is closed")
            } footer: {
                if model.alertsTopic != nil {
                    SettingsNote("In ntfy, tap + and paste this topic (server ntfy.sh). Security challenges, reminders and JARVIS's announcements then arrive even with this app closed or away from home. Only the short alert text goes through ntfy - never photos, your screen or files. Turn this off and on again for a new topic.")
                } else {
                    SettingsNote("Off. JARVIS's alerts reach this iPhone only while the app is open (or listening in the background).")
                }
            }

            if model.alertsTopic != nil {
                Section {
                    Link(destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!) {
                        HStack {
                            Image(systemName: "arrow.down.app").frame(width: 20)
                            Text("Get the ntfy app")
                            Spacer()
                        }
                    }
                    .foregroundStyle(HUD.accent)
                    .hudRow()
                }
            }
        }
        .hudList()
    }
}

// MARK: - Mobile JARVIS

/// What this node can do, and what belongs to the other one.
///
/// Both halves on one page on purpose. "What can you do with my PC off?" is answered by the first
/// list; the second is why the phone can say "that one is your PC's, and it isn't answering"
/// instead of showing a transport error. A node that knows what the other nodes do is the whole
/// idea, and this is where it is visible.
private struct MobileCapabilitiesPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var home = SmartHomeModel.shared
    @ObservedObject private var footage = FootageModel.shared

    private var state: MobileCapabilities.NodeState { model.nodeState }

    var body: some View {
        List {
            Section {
                StatusRow(title: "On its own", status: .ready("\(MobileCapabilities.standalone(state).count) of \(thisPhone.count)"))
                StatusRow(title: state.pcName, status: state.pcAnswering ? .live("Answering") : .configured("Not answering"))
            } header: {
                HUDSectionTitle(text: "Now")
            } footer: {
                SettingsNote("Mobile JARVIS is a node of the same JARVIS, not a remote control for it. With your PC off it still does what a phone is the right machine for, and says plainly when a request belongs to the PC.")
            }

            Section {
                ForEach(thisPhone) { CapabilityRow(card: $0) }
            } header: {
                HUDSectionTitle(text: "This phone does these")
            }

            Section {
                ForEach(pcPrime) { CapabilityRow(card: $0) }
            } header: {
                HUDSectionTitle(text: "PC-Prime does these")
            } footer: {
                SettingsNote("Understanding, memory, research and the screen are the PC's, and that is deliberate: it is where JARVIS lives, where the tools are, and where the state of record is kept. A phone that answered these in its own words would be a worse JARVIS wearing the same name.")
            }
        }
        .hudList()
    }

    private var thisPhone: [MobileCapabilityCard] {
        MobileCapabilities.cards(state).filter { $0.node == .thisPhone }
    }

    private var pcPrime: [MobileCapabilityCard] {
        MobileCapabilities.cards(state).filter { $0.node == .pcPrime }
    }
}

private struct CapabilityRow: View {
    let card: MobileCapabilityCard

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: card.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(status.colour)
                    .frame(width: 24)
                Text(card.title).foregroundStyle(HUD.text)
                Spacer(minLength: 8)
                StatusDot(status: status)
            }
            Text(card.detail)
                .font(.caption)
                .foregroundStyle(HUD.dim)
                .fixedSize(horizontal: false, vertical: true)

            // Only when there is something to do about it. A row that says "ready" twice is noise.
            if case .needs(let what) = card.readiness {
                Text(what)
                    .font(.caption)
                    .foregroundStyle(HUD.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .hudRow()
    }

    /// The readiness as the list's own status vocabulary, so one dot means one thing everywhere.
    private var status: SettingsStatus {
        switch card.readiness {
        case .standalone: return .live("Works with the PC off")
        case .throughThePC: return .ready("Through the PC")
        case .needs: return .attention("Needs setting up")
        case .waitingForThePC: return .configured("The PC isn't answering")
        }
    }
}

private struct StandbyLightsPage: View {
    var body: some View {
        List {
            Section {
                StandbySection()
                    .hudPanelRow()
            }
        }
        .hudList()
    }
}

private struct WhereaboutsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                WhereaboutsSection(reporter: model.whereabouts)
                    .hudPanelRow()
            }
        }
        .hudList()
    }
}

// MARK: - PC-Prime

private struct WakingPage: View {
    @EnvironmentObject var model: AppModel

    @State private var wakeMac = ""
    @State private var wakeBroadcast = ""
    @State private var problem: String?
    @State private var host = AppModel.shared.wakeProfile.remoteHost
    @State private var port = String(AppModel.shared.wakeProfile.remotePort)

    var body: some View {
        List {
            Section {
                ToggleRow(title: "Wake-on-LAN",
                          isOn: Binding(get: { model.wakeProfile.enabled },
                                        set: { model.setWakeEnabled($0) }))
                StatusRow(title: "Ready", status: readiness)
            } header: {
                HUDSectionTitle(text: "Waking \(model.wakeProfile.deviceName)")
            }

            if let mac = model.wakeProfile.mac {
                Section {
                    ValueRow(title: "MAC", value: mac.description)
                    ValueRow(title: "From home", value: "\(model.wakeProfile.broadcast):\(model.wakeProfile.port)")
                } header: {
                    HUDSectionTitle(text: "Its card")
                } footer: {
                    if model.wakeProfile.typedByHand == true {
                        SettingsNote("Typed by hand, and kept: connecting to the PC will not overwrite it.")
                    } else {
                        SettingsNote("Learnt from the PC itself.")
                    }
                }
            } else {
                Section {
                    HUDField(prompt: "Card address (04-7C-16-4E-A7-F5)", text: $wakeMac, keyboard: .asciiCapable)
                        .hudRow()
                    HUDField(prompt: "Home broadcast address (192.168.1.255)", text: $wakeBroadcast, keyboard: .numbersAndPunctuation)
                        .hudRow()
                    ActionRow(title: "Save the card", symbol: "square.and.arrow.down",
                              disabled: wakeMac.isEmpty || wakeBroadcast.isEmpty) {
                        problem = model.setWakeCard(mac: wakeMac, broadcast: wakeBroadcast)
                    }
                    if let problem {
                        SettingsNote(problem, colour: HUD.alert).hudRow()
                    }
                } header: {
                    HUDSectionTitle(text: "Its card")
                } footer: {
                    SettingsNote("Connect to the PC once at home and it tells this phone its card's address and the home network's broadcast address - there is nothing to type.\n\nIf it has been off the whole time, type them instead. Both are on the PC's own `SpeechDiag network` screen, and on your router's page.")
                }
            }

            Section {
                HUDField(prompt: "Remote wake host (a DDNS name, or your home IP)", text: $host, keyboard: .URL)
                    .hudRow()
                HUDField(prompt: "Remote wake port", text: $port, keyboard: .numberPad)
                    .hudRow()
                ToggleRow(title: "Allow waking over mobile data",
                          isOn: Binding(get: { model.wakeProfile.overCellular },
                                        set: { model.setWakeOverCellular($0) }))
                ActionRow(title: "Save", symbol: "square.and.arrow.down") {
                    model.setWakeRemote(host: host, port: UInt16(port))
                }
            } header: {
                HUDSectionTitle(text: "From outside the house")
            } footer: {
                SettingsNote("Your router has to forward that port to \(model.wakeProfile.broadcast.isEmpty ? "your home network's broadcast address" : model.wakeProfile.broadcast) on UDP \(model.wakeProfile.port). Use a dynamic-DNS name rather than your home IP address, which your provider will change. A wake request proves nothing about who sent it - the protocol has no secret in it - so the only thing that port can ever do is switch the PC on.")
            }

            if let last = model.wakeProfile.lastAttempt {
                Section {
                    ValueRow(title: "Last request", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .hudList()
    }

    /// Set up at home, set up from away, or not set up - three different answers, and the old panel
    /// gave none of them.
    private var readiness: SettingsStatus {
        guard model.wakeProfile.enabled else { return .off("Off") }
        if model.wakeProfile.reachableRemotely { return .ready("At home and from away") }
        if model.wakeProfile.usable { return .ready("At home only") }
        return .attention("Needs the PC's card")
    }
}

private struct ReachingPage: View {
    @EnvironmentObject var model: AppModel

    @State private var host = AppModel.shared.pc?.remoteHost ?? ""

    var body: some View {
        List {
            Section {
                StatusRow(title: "Connected", status: model.route.map { SettingsStatus.live($0) } ?? .configured("Not connected"))
                ToggleRow(title: "Prefer the home network when it is there",
                          isOn: Binding(get: { model.pc?.preferLocal ?? true },
                                        set: { model.setPreferLocal($0) }))
            } header: {
                HUDSectionTitle(text: "Now")
            }

            if let known = model.pc?.remoteHosts, !known.isEmpty {
                Section {
                    ForEach(known, id: \.self) { host in
                        CopyableValue(title: "Address", value: host)
                    }
                } header: {
                    HUDSectionTitle(text: "Where the PC says it can be found")
                }
            }

            Section {
                HUDField(prompt: "Another address for the PC (optional)", text: $host, keyboard: .URL)
                    .hudRow()
                ActionRow(title: "Save and reconnect", symbol: "arrow.clockwise") {
                    model.setRemoteHost(host)
                    Task { await model.disconnect(); await model.connect() }
                }
                NavigationRow(title: "Connection diagnostics",
                              symbol: "stethoscope",
                              destination: .diagnostics)
            } header: {
                HUDSectionTitle(text: "By hand")
            } footer: {
                SettingsNote("To use JARVIS on mobile data: install Tailscale on the PC and on this iPhone and sign in to the same account on both. Connect to the PC once at home after that and it tells this phone where to find it - there is nothing to type. Everything stays encrypted end to end exactly as it is at home; Tailscale only carries it, and the PC still has to prove it is the PC this phone paired with.")
            }

            if !model.connectionLog.isEmpty {
                Section {
                    LogBlock(title: "Last attempt", lines: model.connectionLog)
                }
            }
        }
        .hudList()
    }
}

// MARK: - Smart home

/// What JARVIS can switch, and *through which node* - which is the one fact the Home tab does not
/// show and the one somebody debugging a light at midnight needs.
private struct SmartHomePage: View {
    @ObservedObject private var home = SmartHomeModel.shared
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                ValueRow(title: "Devices", value: "\(home.devices.count)", monospaced: false)
                ValueRow(title: "This phone can reach", value: "\(home.standby.count)", monospaced: false)
                StatusRow(title: "Own token", status: home.credentials != nil ? .ready("In the Keychain") : .off("None"))
            } header: {
                HUDSectionTitle(text: "The house")
            } footer: {
                SettingsNote("A command normally goes to your PC, which owns the state and tells every other device what changed. With the PC off, this phone can send it straight to the vendor for the devices below - and only those.")
            }

            if !home.devices.isEmpty {
                Section {
                    ForEach(home.devices) { device in
                        DeviceReachRow(device: device, reachable: home.canWork(device))
                    }
                } header: {
                    HUDSectionTitle(text: "Each device")
                }
            }

            Section {
                NavigationRow(title: "Switching lights without the PC",
                              subtitle: "This phone's own SwitchBot token.",
                              symbol: "lightbulb",
                              destination: .standbyLights)
            }
        }
        .hudList()
        .task { await home.refresh() }
    }
}

private struct DeviceReachRow: View {
    let device: SmartDevice
    let reachable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(device.name).foregroundStyle(HUD.text)
                Spacer()
                Text(device.statusText.isEmpty ? device.shown.rawValue : device.statusText)
                    .font(.caption)
                    .foregroundStyle(device.isOn ? HUD.bright : HUD.dim)
            }
            HStack(spacing: 8) {
                if let room = device.room {
                    Text(room).font(.caption2).foregroundStyle(HUD.dim)
                }
                Text(reachable ? "PC or this phone" : "PC only")
                    .font(.caption2)
                    .foregroundStyle(reachable ? HUD.accent : HUD.dim)
                if let battery = device.battery {
                    Text("\(battery)%").font(.caption2).foregroundStyle(HUD.dim)
                }
            }
        }
        .hudRow()
    }
}

// MARK: - Devices and power

/// What this phone can read about power, and what it cannot - programme §17.
///
/// The second half is as much the point as the first. iOS gives an app its own battery and gives
/// it nothing at all about anything paired over Bluetooth, so a page showing only what it can read
/// would leave the owner wondering why their AirPods are missing. Named, with the reason, is the
/// honest answer - and it is the same `because` the PC says aloud.
private struct PowerPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var reporter = PowerReporter.shared

    var body: some View {
        List {
            Section {
                ForEach(reporter.readings) { PowerRow(reading: $0) }
            } header: {
                HUDSectionTitle(text: "This phone")
            } footer: {
                SettingsNote("Sent to your PC with the time each reading was taken, so it can say how a device is doing - and say how old the answer is rather than stating an hour-old figure as if it were now. Nothing about a battery is kept: it is true for minutes, so it never goes into what JARVIS remembers about you.")
            }

            Section {
                StatusRow(title: "Reporting",
                          status: model.link.isOnline ? .live("To \(model.pcName)") : .configured("Waiting for the PC"))
                ActionRow(title: "Read and send now", symbol: "arrow.clockwise") {
                    Task { await reporter.reportEverything() }
                }
            } header: {
                HUDSectionTitle(text: "The PC")
            }

            Section {
                SettingsNote("Ask JARVIS \u{201C}what\u{2019}s my phone\u{2019}s battery\u{201D} and this phone answers it itself, with your PC on or off - the one power question the PC cannot look up, because a battery is readable only by the device it is in.")
                    .hudRow()
            }
        }
        .hudList()
        .task { reporter.read() }
    }
}

private struct PowerRow: View {
    let reading: PowerReading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(level)
                    .frame(width: 26)
                Text(reading.name).foregroundStyle(HUD.text)
                Spacer(minLength: 8)
                if let percent = reading.percent {
                    Text("\(percent)%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(level)
                } else {
                    Text("not reported").font(.caption).foregroundStyle(HUD.dim)
                }
            }

            if reading.charge == .charging || reading.charge == .full {
                Text(reading.charge == .full ? "Charged" : "Charging")
                    .font(.caption).foregroundStyle(HUD.accent)
            }

            if reading.lowPowerMode {
                Text("Low Power Mode is on").font(.caption).foregroundStyle(HUD.amber)
            }

            if let because = reading.because {
                Text(because)
                    .font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .hudRow()
    }

    /// The battery drawn at the level it is at, which reads at a glance where a number does not.
    private var symbol: String {
        guard let percent = reading.percent else { return "questionmark.circle" }
        if reading.charge == .charging { return "battery.100.bolt" }
        if percent >= 75 { return "battery.100" }
        if percent >= 50 { return "battery.75" }
        if percent >= 25 { return "battery.50" }
        return percent >= 10 ? "battery.25" : "battery.0"
    }

    /// Amber and red are the two exceptions the palette keeps, and a low battery earns one.
    private var level: Color {
        guard let percent = reading.percent else { return HUD.dim }
        if reading.charge == .charging || reading.charge == .full { return HUD.bright }
        if percent <= 10 { return HUD.alert }
        return percent <= 20 ? HUD.amber : HUD.accent
    }
}

// MARK: - Security

private struct FootageStorePage: View {
    var body: some View {
        List {
            Section {
                StoreSection()
                    .hudPanelRow()
            }
        }
        .hudList()
    }
}

// MARK: - Learning

private struct LearningPage: View {
    var body: some View {
        List {
            Section {
                LearningSection(learning: LearningModel.shared)
                    .hudPanelRow()
            }
        }
        .hudList()
    }
}

// MARK: - Advanced

private struct DiagnosticsPage: View {
    var body: some View {
        ConnectionDiagnosticsView(embedded: true)
    }
}

private struct EncryptionPage: View {
    @State private var results: [(name: String, passed: Bool)] = []

    var body: some View {
        List {
            Section {
                ActionRow(title: "Run", symbol: "play.circle") { results = BridgeSelfTest.run() }
                ForEach(results.indices, id: \.self) { index in
                    HStack {
                        Image(systemName: results[index].passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(results[index].passed ? HUD.good : HUD.alert)
                        Text(results[index].name).foregroundStyle(HUD.text)
                        Spacer()
                    }
                    .hudRow()
                }
            } footer: {
                SettingsNote("Checks this iPhone computes the same keys, digits and frames as the PC.")
            }
        }
        .hudList()
    }
}

private struct ForgetPage: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming = false

    var body: some View {
        List {
            Section {
                DangerRow(title: "Forget this PC") { confirming = true }
            } footer: {
                SettingsNote("Deletes this phone's keys. Also press Forget next to this iPhone on the PC.")
            }
        }
        .hudList()
        .confirmationDialog("Forget this PC?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await model.forget() } }
        }
    }
}

private struct AboutPage: View {
    @EnvironmentObject var model: AppModel

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                ValueRow(title: "This app", value: appVersion)
                ValueRow(title: "JARVIS on the PC", value: model.status["version"] as? String ?? "-")
                ValueRow(title: "iOS", value: UIDevice.current.systemVersion)
                ValueRow(title: "Device", value: UIDevice.current.model, monospaced: false)
            } header: {
                HUDSectionTitle(text: "Versions")
            }

            Section {
                SettingsNote("Mobile JARVIS is a node of the same JARVIS that runs on your PC, not a remote control for it. It shares the memory, the devices and the knowledge; it does the things a phone is the right machine for, and asks the PC for the things the PC is. With your PC off it still answers what it can answer on its own, and says so plainly when it cannot.")
                    .hudRow()
            }
        }
        .hudList()
    }
}
