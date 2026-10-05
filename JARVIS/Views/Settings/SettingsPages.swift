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
            case .knownPlaces: KnownPlacesPage()
            case .notices: NoticeCategoriesPage()
            case .vocabulary: VocabularyPage()
            case .waking: WakingPage()
            case .reaching: ReachingPage()
            case .smartHome: SmartHomePage()
            case .homeIndependence: HomeIndependencePage()
            case .power: PowerPage()
            case .footageStore: FootageStorePage()
            case .sharedJarvis: SharedJarvisPage()
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
            AvailabilityPanel()

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

/// The places this phone holds, what it currently makes of where it is, and the owner's own names.
///
/// This is the screen that makes the place model judgeable. A learned place is a claim about the
/// owner's life, and the only check that matters is the owner reading it - so every row shows the
/// evidence behind it: how many visits, whether they named it themselves, and the usual times if a
/// routine has earned one.
private struct KnownPlacesPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var book = MobilePlaceBook.shared
    @ObservedObject private var routines = MobileRoutineBook.shared

    @State private var renaming: MobilePlace?
    @State private var typed = ""
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ValueRow(title: "Right now", value: PlaceAnswers.whereAmI(verdict))
            } header: {
                HUDSectionTitle(text: "Where you are")
            } footer: {
                SettingsNote(
                    "Worked out on this phone, from the places below. It needs no connection to "
                    + "your PC and no model.")
            }

            if book.places.isEmpty {
                Section {
                    SettingsNote(
                        "Nothing yet. Your PC learns a place once you have stopped in it a few "
                        + "times, and sends the useful ones here on the next connection.")
                }
            } else {
                Section {
                    ForEach(book.places) { place in
                        Button {
                            renaming = place
                            typed = place.name
                        } label: {
                            PlaceRow(place: place, patterns: routines.about(place))
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HUDSectionTitle(text: "\(book.places.count) place\(book.places.count == 1 ? "" : "s")")
                } footer: {
                    SettingsNote(
                        "Tap a place to name it. What you type wins over anything JARVIS worked "
                        + "out, on every node, and it is what you will hear said out loud.")
                }
            }

            Section {
                ValueRow(title: "Place revision", value: String(book.revision))
                ValueRow(title: "Patterns held", value: String(routines.routines.count))

                if let at = book.syncedAt {
                    ValueRow(title: "Last caught up", value: at.formatted(date: .omitted, time: .shortened))
                }

                if let because = book.problem {
                    ValueRow(title: "Last problem", value: because)
                }
            } header: {
                HUDSectionTitle(text: "Catching up")
            } footer: {
                SettingsNote("Incremental, on every connection, with no button. Up to \(MobilePlaceProtocol.most) places are kept here.")
            }
        }
        .hudList()
        .alert("Name this place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Home", text: $typed)

            Button("Save") { Task { await name() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("What you call it. JARVIS will use this word, and so will your PC.")
        }
        .alert("That didn't work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("All right", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var verdict: PlaceVerdict {
        PlaceResolution.read(model.whereabouts.fix, in: book.places)
    }

    private func name() async {
        guard let place = renaming else { return }

        let said = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil

        guard !said.isEmpty else { return }

        do {
            _ = try await model.exchanging("places.name", ["id": place.id, "name": said])

            // Pulled back rather than patched locally, so the revision the PC assigned is the one
            // this phone holds - otherwise the next incremental pull would send it again.
            await model.pullPlaces()
        } catch {
            problem = MobilePlaceBook.because(error)
        }
    }
}

/// One place, with the evidence behind it rather than only its name.
private struct PlaceRow: View {
    let place: MobilePlace
    let patterns: [MobileRoutine]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(place.name.isEmpty ? "Unnamed" : place.name)
                    .font(.headline)

                Spacer()

                if place.named {
                    Text("your name")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(patterns) { pattern in
                Text(PlaceAnswers.describe(pattern))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Never a coordinate. What the owner can judge the place by.
    private var detail: String {
        var parts: [String] = []

        if !place.category.word.isEmpty { parts.append(place.category.word) }

        parts.append("\(place.visits) visit\(place.visits == 1 ? "" : "s")")

        if place.aliases.count > 0 { parts.append("also: \(place.aliases.joined(separator: ", "))") }

        if let arrives = place.arrives {
            parts.append("usually in around \(PlaceAnswers.clock(minutes: arrives))")
        }

        return parts.joined(separator: " · ")
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
                    Task { await model.refresh() }
                }
            } header: {
                HUDSectionTitle(text: "The PC")
            }

            // §14. The other half of a shared model: a headset's battery is readable only by the
            // machine it is paired to, so this is the only way it reaches a phone at all.
            if !reporter.elsewhere.isEmpty {
                Section {
                    ForEach(reporter.elsewhere) { SharedPowerRow(reading: $0) }
                } header: {
                    HUDSectionTitle(text: "What the other nodes said")
                } footer: {
                    SettingsNote("Worded by your PC from the time each device measured its own level, so a figure that arrived just now is not shown as current unless it is.")
                }
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

/// One other node's reading, in the PC's own words.
///
/// The sentence comes from the PC rather than being rebuilt here: it has the timestamps and has
/// already decided how old the reading is, and two implementations of one freshness rule is how
/// two screens come to disagree about one battery.
private struct SharedPowerRow: View {
    let reading: SharedPowerReading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                StatusDot(status: reading.isLive ? .live("") : .configured(""))
                Text(reading.name).foregroundStyle(HUD.text)
                Spacer(minLength: 8)
                if let percent = reading.percent {
                    Text("\(percent)%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(reading.isLive ? HUD.accent : HUD.dim)
                } else {
                    Text("not reported").font(.caption).foregroundStyle(HUD.dim)
                }
            }
            if !reading.said.isEmpty {
                Text(reading.said)
                    .font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .hudRow()
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


// MARK: - What is available right now - programme §4

/// Which subsystems can be used, whether or not PC-PRIME is answering.
///
/// The panel exists because "JARVIS is offline" is almost never true. With the PC asleep the smart
/// home still works, the footage is still readable, the phone still knows where it is, and a
/// general question can still be answered if the owner has given this phone a provider. A single
/// status collapsing all of that into one word would be wrong in the most useful direction.
struct AvailabilityPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var footage = FootageModel.shared

    var body: some View {
        Section {
            ForEach(MobileStatus.availability(model.nodeState, footageHeld: !footage.incidents.isEmpty)) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(HUD.text)
                        if let detail = row.state.detail {
                            Text(detail).font(.caption).foregroundStyle(HUD.dim)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(row.state.word)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(row.state.usable ? HUD.good : HUD.dim)
                }
                .hudRow()
            }
        } header: {
            HUDSectionTitle(text: "Available now")
        } footer: {
            SettingsNote(model.link.isOnline
                ? "Everything your PC brings is available as well."
                : "Your PC isn't answering. Everything marked available still works without it.")
        }
    }
}

// MARK: - Smart home independence - programme §2

/// Whether this phone could switch a light with the PC off, line by line.
///
/// The page exists because "the light didn't come on" has eight different causes with eight
/// different remedies, and they are indistinguishable from the outside. Each line is one link in
/// the chain, in the order the chain runs, and the banner names the first one that is broken -
/// because telling the owner the hub is unreachable when the real problem is a missing token would
/// send them to look at the hub.
///
/// **The test reads rather than switches.** A status read proves the token, the network, the
/// vendor, the hub and the device without touching the owner's light, which matters when the most
/// likely time to run this is last thing at night. A read that comes back is the whole chain
/// working; nothing else can establish that.
private struct HomeIndependencePage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var home = SmartHomeModel.shared

    @State private var probe: HomeIndependence.Probe?
    @State private var testing = false

    private var report: HomeIndependence {
        HomeIndependence.read(
            credentials: home.credentials,
            bindings: home.standby,
            pcAnswering: model.link.isOnline,
            preferred: subject,
            probe: probe,
            lastCommandAt: lastCommand?.lastSuccessAt,
            lastResult: lastCommand?.lastResult,
            lastConfirmedState: lastCommand?.certainty == .confirmed ? lastCommand?.statusText : nil,
            networkUp: !model.network.offline)
    }

    /// The device the page is about: the one light, or the first thing this phone was taught.
    private var subject: StandbyDevice? {
        home.standby.first { $0.kind == "light" } ?? home.standby.first
    }

    private var lastCommand: SmartDevice? {
        subject.flatMap { binding in home.shown.first { $0.id == binding.id } }
    }

    var body: some View {
        List {
            if let blocker = report.blocker {
                Section {
                    SettingsNote("\(blocker.title): \(blocker.remedy)", colour: HUD.amber)
                        .hudRow()
                } header: {
                    HUDSectionTitle(text: "What is stopping it")
                }
            }

            Section {
                StatusRow(title: "Route if asked now", status: route)
            } footer: {
                SettingsNote(model.link.isOnline
                    ? "Your PC is answering, so commands go through it. That is the right route: the PC owns the state and tells every other node what changed."
                    : "Your PC isn't answering, so this is what the phone would do by itself.")
            }

            Section {
                CheckRow(title: "SwitchBot credentials", check: report.credentials)
                CheckRow(title: "Device bindings", check: report.bindings)
                CheckRow(title: subject.map { "\($0.name) known" } ?? "A device known", check: report.device)
                CheckRow(title: "Direct vendor route", check: report.directRoute)
                CheckRow(title: "PC route", check: report.pcRoute)
                CheckRow(title: "Hub reachable", check: report.hub)
            } header: {
                HUDSectionTitle(text: "The chain")
            } footer: {
                SettingsNote("In the order it runs. The first NO is the one worth fixing.")
            }

            Section {
                ActionRow(title: testing ? "Reading…" : "Test the direct route", symbol: "stethoscope") {
                    Task { await test() }
                }
                .disabled(testing || subject == nil || home.credentials == nil)

                if let probe {
                    ValueRow(title: "Last read", value: Self.when(probe.at), monospaced: false)
                    SettingsNote(probe.outcome.sentence,
                                 colour: probe.blocker == nil ? HUD.good : HUD.amber)
                        .hudRow()
                    if let battery = probe.battery {
                        ValueRow(title: "Device battery", value: "\(battery)%", monospaced: false)
                    }
                }
            } header: {
                HUDSectionTitle(text: "Test")
            } footer: {
                SettingsNote("Reads the switch rather than working it, so nothing in the room changes. A read that comes back proves the token, the network, SwitchBot, the hub and the device all at once.")
            }

            Section {
                ValueRow(title: "Last command", value: report.lastCommandAt.map(Self.when) ?? "None yet", monospaced: false)
                if let result = report.lastResult {
                    SettingsNote(result).hudRow()
                }
                ValueRow(title: "Last confirmed state", value: report.lastConfirmedState ?? "Not confirmed", monospaced: false)
            } header: {
                HUDSectionTitle(text: "History")
            }
        }
        .hudList()
    }

    private var route: SettingsStatus {
        switch report.routeNow {
        case .pc: return .live("PC")
        case .mobileDirect: return .ready("MOBILE DIRECT")
        case .unavailable(let why): return .fault("UNAVAILABLE — \(why)")
        }
    }

    private func test() async {
        guard let binding = subject, let credentials = home.credentials else { return }

        testing = true
        defer { testing = false }

        let vendor = SwitchBotStandby(credentials: credentials, wiring: home.wiring)
        let (outcome, battery) = await vendor.read(binding.vendorDeviceId)

        probe = HomeIndependence.Probe(at: Date(), outcome: outcome, device: binding.name, battery: battery)
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// One link of the chain: its name, YES/NO/UNKNOWN, and what makes it so.
private struct CheckRow: View {
    let title: String
    let check: HomeCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(HUD.text)
                if let detail = check.detail {
                    Text(detail).font(.caption).foregroundStyle(HUD.dim)
                }
            }
            Spacer(minLength: 12)
            Text(check.word)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(colour)
        }
        .hudRow()
    }

    private var colour: Color {
        switch check {
        case .yes: return HUD.good
        case .no: return HUD.amber
        case .unknown: return HUD.dim
        }
    }
}

// MARK: - One JARVIS - programme §64

/// What this phone has told the PC, and what it has heard back.
///
/// There is no Sync button here, and that is the point rather than an omission: the owner granted
/// the pairing, and being asked to press Sync afterwards would mean JARVIS knew less than it could
/// because nobody tapped. The page reports; it does not ask for permission to work.
private struct SharedJarvisPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var timeline = OwnerTimelineClient.shared

    var body: some View {
        List {
            Section {
                StatusRow(title: "Exchange", status: exchange)
                ValueRow(title: "Waiting to send", value: "\(timeline.state.queued)")
                ValueRow(title: "Held from your PC", value: "\(timeline.state.kept)")
                ValueRow(title: "Last exchange", value: timeline.state.lastSync.map(Self.when) ?? "Not yet", monospaced: false)
            } header: {
                HUDSectionTitle(text: "This phone")
            } footer: {
                SettingsNote("Observations made with your PC off wait here and go on their own as soon as there is a route. Nothing needs pressing.")
            }

            Section {
                ValueRow(title: "This phone has", value: "\(timeline.state.cursor)")
                ValueRow(title: "Your PC has", value: "\(timeline.state.pcRevision)")
                if timeline.state.behind {
                    SettingsNote("Catching up on \(timeline.state.pcRevision - timeline.state.cursor) more.", colour: HUD.accent)
                        .hudRow()
                }
                if let problem = timeline.state.problem {
                    SettingsNote(problem, colour: HUD.amber).hudRow()
                }
            } header: {
                HUDSectionTitle(text: "Revisions")
            } footer: {
                SettingsNote("Counting positions in your PC's log, so catching up costs what has changed rather than everything.")
            }

            if !recent.isEmpty {
                Section {
                    ForEach(recent) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.say(event)).foregroundStyle(HUD.text)
                            Text(Self.when(event.occurred)).font(.caption).foregroundStyle(HUD.dim)
                        }
                        .hudRow()
                    }
                } header: {
                    HUDSectionTitle(text: "What your PC has told this phone")
                } footer: {
                    SettingsNote("Semantic observations, not a log. Anywhere precise is withheld.")
                }
            }
        }
        .hudList()
    }

    /// The last few, with anything sensitive described rather than printed.
    private var recent: [OwnerEvent] { Array(timeline.kept.prefix(12)) }

    private var exchange: SettingsStatus {
        if timeline.state.problem != nil { return .attention("Last attempt did not go") }
        if !model.link.isOnline { return .configured("Waiting for the PC") }
        return timeline.state.lastSync == nil ? .ready("Ready") : .live("Automatic")
    }

    /// One event as a line the owner would recognise.
    ///
    /// Deliberately not the payload. A sensitive event names what happened and the place the owner
    /// chose to call it, and nothing else - a diagnostic page is exactly the sort of screen
    /// somebody photographs to ask for help with.
    private static func say(_ event: OwnerEvent) -> String {
        let place = event.value("place")
        let app = event.value("app")
        let device = event.value("device")

        switch event.type {
        case OwnerEventTypes.arrived: return "Arrived\(place.map { " at \($0)" } ?? "")"
        case OwnerEventTypes.left: return "Left\(place.map { " \($0)" } ?? "")"
        case OwnerEventTypes.deviceWorked: return "Worked \(device ?? "a device")"
        case OwnerEventTypes.nodeUp: return "\(event.value("name") ?? "A node") came online"
        case OwnerEventTypes.nodeDown: return "\(event.value("name") ?? "A node") went offline"
        case OwnerEventTypes.asked: return "A conversation"
        default:
            if let app { return app }
            return event.type
        }
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Which kinds of notification reach this phone - priority §7A and §7B.
///
/// One screen, because the brief asks for one canonical place and because the alternative is what
/// this app had: notification behaviour decided by whichever screen happened to produce each kind.
/// An owner who wants fewer interruptions should not have to find them.
private struct NoticeCategoriesPage: View {
    @ObservedObject private var settings = NoticeSettings.shared

    var body: some View {
        List {
            Section {
                SettingsNote(
                    "Each of these is a kind of thing worth telling you about. Turning one off "
                    + "stops that kind reaching this phone; it does not stop JARVIS noticing.")
            }

            ForEach(MobileNoticeCategory.allCases) { category in
                Section {
                    if category.optional {
                        Toggle(isOn: Binding(
                            get: { settings.wants(category) },
                            set: { settings.set(category, wanted: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                Text(category.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        // Security, which cannot be switched off. Shown as a row rather than a
                        // disabled toggle, because a toggle the owner cannot move is a toggle they
                        // try to move.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                            Text(category.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Always on. This is the one kind where not telling you could matter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if settings.changed(category) {
                        Button("Use the default") { settings.useDefault(category) }
                            .font(.caption)
                    }
                }
            }

            Section {
                SettingsNote(
                    "Syncing, routine suggestions and learning are off here by default. You can "
                    + "see all of them in the app whenever you like; a notification about them "
                    + "would mostly be a buzz you learn to ignore.")
            } header: {
                HUDSectionTitle(text: "Why some are off")
            }
        }
        .navigationTitle("What I tell you about")
    }
}

/// The owner's own words for things, and how sure JARVIS is of each - priority §6A and §6B.
///
/// Read-only on purpose. The way to change what a word means is to correct JARVIS when it gets it
/// wrong, which is both easier than finding this screen and the thing that produces the strongest
/// evidence. This is here so the owner can see what it believes and why.
private struct VocabularyPage: View {
    @ObservedObject private var book = MobileAliases.shared

    var body: some View {
        List {
            if book.aliases.isEmpty {
                Section {
                    SettingsNote(
                        "Nothing yet. When you correct me - \"no, the bedroom light\" - I remember "
                        + "the word you used, and both this phone and your PC use it from then on.")
                }
            }

            ForEach(book.aliases) { alias in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\u{201C}\(alias.said)\u{201D}")
                            .font(.body.weight(.medium))

                        Text(alias.entity)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // The provenance rather than the conclusion. "It means the bedroom light"
                        // is uninteresting; "because you said so, twice" is what lets the owner
                        // decide whether to agree.
                        Text(because(alias))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let failed = book.failed {
                Section {
                    SettingsNote("Last time I tried to catch up: \(failed)")
                } header: {
                    HUDSectionTitle(text: "Syncing")
                }
            }
        }
        .navigationTitle("What your words mean")
    }

    private func because(_ alias: MobileAlias) -> String {
        let how = switch alias.strength {
        case .veryStrong: "because you told me"
        case .strong: "from commands that worked"
        case .medium: "from what you usually do"
        case .weak: "from one thing I noticed"
        }

        let times = alias.count == 1 ? "once" : "\(alias.count) times"

        return alias.trusted
            ? "\(how), \(times). I act on this."
            : "\(how), \(times). Not enough for me to act on yet."
    }
}
