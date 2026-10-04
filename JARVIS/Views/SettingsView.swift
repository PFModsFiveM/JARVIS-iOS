import SwiftUI

/// Settings: a grouped list of pages, searchable, with a link to every one of them.
///
/// This replaced one 434-line `ScrollView` holding a `VStack` of decorative panels, and the shape
/// was the problem rather than the contents. The old page could not be searched, could not be
/// linked into, had no two rows that looked alike, and had reached the ViewBuilder's ten-child
/// limit - there is still a comment in the history explaining that two panels were wrapped in a
/// `Group` because the eleventh would not compile. It also would not scroll unless the drag began
/// on the scroll indicator: two `.textSelection(.enabled)` modifiers had been put on *containers*,
/// and selectable text claims a drag before the scroller sees it. See the note at the top of
/// `Settings/HUDList.swift`.
///
/// What is here instead: the hierarchy declared as data in `SettingsCatalogue`, a native `List`
/// that owns its own scrolling, one row system in `Settings/HUDList.swift`, and `SettingsPage` to
/// turn a destination into a view. Adding a settings page is one row in the catalogue and one case
/// in that switch, and it is then in the list, in the search results and at a `jarvis://settings/`
/// link without anything else being touched.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [SettingsDestination] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    nowSection
                    ForEach(SettingsCatalogue.categories, id: \.self) { category in
                        Section {
                            ForEach(SettingsCatalogue.entries(in: category)) { entry in
                                NavigationRow(title: entry.title,
                                              subtitle: entry.subtitle,
                                              symbol: entry.symbol,
                                              status: status(of: entry.destination),
                                              destination: entry.destination)
                            }
                        } header: {
                            HUDSectionTitle(text: category.title)
                        } footer: {
                            if let note = category.note { SettingsNote(note) }
                        }
                    }
                } else {
                    results
                }
            }
            .hudList()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .autocorrectionDisabled()
            .hudTitle("Settings")
            .navigationDestination(for: SettingsDestination.self) { SettingsPage(destination: $0) }
        }
        // A link may arrive while this tab is already open, or be what brought it to the front.
        .onChange(of: model.settingsRoute) { _, route in follow(route) }
        .onAppear { follow(model.settingsRoute) }
    }

    /// §21. What is true at this moment, above the things that are merely configured - so the first
    /// thing the page says is whether JARVIS is reachable, not how to set it up.
    @ViewBuilder private var nowSection: some View {
        Section {
            StatusRow(title: model.pcName, status: linkStatus)
            if model.onCellular {
                StatusRow(title: "Network", status: .ready("Mobile data"))
            }
        } header: {
            HUDSectionTitle(text: "Now", tint: HUD.accent)
        }
    }

    private var results: some View {
        let found = SettingsCatalogue.search(query)
        return Group {
            if found.isEmpty {
                SettingsNote("Nothing in Settings matches that.").hudRow()
            } else {
                ForEach(found) { entry in
                    NavigationRow(title: entry.title,
                                  subtitle: entry.category.title,
                                  symbol: entry.symbol,
                                  status: status(of: entry.destination),
                                  destination: entry.destination)
                }
            }
        }
    }

    private var linkStatus: SettingsStatus {
        switch model.link {
        case .online: return .live("Connected")
        case .connecting: return .ready("Connecting")
        case .offline(let why): return .configured(why ?? "Not answering")
        case .unpaired: return .off("Not paired")
        }
    }

    /// The badge on a row in the list. Only where there is something worth knowing before tapping -
    /// a row with nothing to say carries no dot, which is what makes the dots mean something.
    private func status(of destination: SettingsDestination) -> SettingsStatus? {
        switch destination {
        case .waking:
            guard model.wakeProfile.enabled else { return .off("Off") }
            return model.wakeProfile.usable ? .ready("Ready") : .attention("Incomplete")
        case .alerts:
            return model.alertsTopic != nil ? .ready("On") : .off("Off")
        case .standbyLights:
            return SmartHomeModel.shared.credentials != nil ? .ready("Has a token") : .off("No token")
        case .footageStore:
            return FootageModel.shared.credentials != nil ? .ready("Joined") : .off("Not joined")
        case .whereabouts:
            return model.whereabouts.reporting ? .live("Reporting") : .off("Off")
        case .connection:
            return model.link.isOnline ? nil : linkStatus
        default:
            return nil
        }
    }

    /// Opens the page a `jarvis://settings/<slug>` link named, replacing whatever was open rather
    /// than stacking on it - a link is a destination, not a step deeper.
    private func follow(_ route: SettingsDestination?) {
        guard let route else { return }
        path = [route]
        model.settingsRoute = nil
    }
}

/// The one thing this phone needs to switch a light while the PC is off: its own SwitchBot token.
///
/// Typed in here, kept in the Keychain and nowhere else, and never sent anywhere but SwitchBot. The
/// PC is not asked for it and cannot supply it: a bridge request that could hand a token over would
/// be a way to take the account from any phone that ever paired, and one revocable token in two
/// places is the cheaper risk.
///
/// The field is a `SecureField`, so the value is never on screen, never in a screenshot and never in
/// the keyboard's own learning. Once stored it is not read back out - the section says it has one.
struct StandbySection: View {
    @ObservedObject private var home = SmartHomeModel.shared

    @State private var token = ""
    @State private var secret = ""
    @State private var saved = false

    var body: some View {
        HUDFrame(title: "Switching lights without the PC") {
            if home.credentials != nil {
                Text(stored)
                    .font(.footnote).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)

                Button(HUD.spaced("Forget the token")) {
                    home.forgetCredentials()
                    token = ""
                    secret = ""
                    saved = false
                }
                .buttonStyle(HUDButtonStyle())
            } else {
                Text("Normally a light is switched through your PC, which is right: it keeps the state and tells every other device what changed. A PC that is off cannot pass the command on, though - so with a SwitchBot token of its own, this phone can send it directly instead.\n\nFind the token and secret in the SwitchBot app under Profile \u{203A} Preferences \u{203A} Developer Options. They are kept in this phone's Keychain, never synced to iCloud and never sent to your PC.")
                    .font(.footnote).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(HUD.spaced("Save to the Keychain")) {
                    home.remember(token: token, secret: secret)
                    token = ""
                    secret = ""
                    saved = home.credentials != nil
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(token.isEmpty || secret.isEmpty)

                if saved && home.credentials == nil {
                    Text("That did not look like a token and a secret.")
                        .font(.footnote).foregroundStyle(HUD.amber)
                }
            }
        }
    }

    /// What it can actually do with the token, which is not the same as having one.
    private var stored: String {
        if home.standby.isEmpty {
            return "This phone has a SwitchBot token. It has not been told which devices it may work yet - connect to your PC once while it is on, and it will remember."
        }

        let names = home.standby.map(\.name).sorted().joined(separator: ", ")
        return "This phone has a SwitchBot token and can work \(names) while your PC is off. The Hub still has to be powered and online: if it is plugged into the PC's USB, it loses power with the PC."
    }
}

/// The bucket credential this phone reads the shared store with.
///
/// The store is where the PC puts what the camera kept, so the phone can read it with the PC off.
/// The PC hands over the bucket's coordinates and the sealing key - that part needs Face ID - and
/// deliberately does not hand over a credential, so this one can be scoped read-only. A phone that
/// is lost then reads what it could already read and cannot delete or overwrite the bucket.
///
/// `SecureField`, so the secret is never on screen, never in a screenshot and never in the
/// keyboard's own learning. Once stored it is not read back out.
struct StoreSection: View {
    @ObservedObject private var stored = FootageModel.shared

    @State private var keyId = ""
    @State private var secret = ""

    var body: some View {
        HUDFrame(title: "Watching the camera without your PC") {
            Text(stored.summary)
                .font(.footnote).foregroundStyle(HUD.dim)
                .fixedSize(horizontal: false, vertical: true)

            if stored.credentials == nil {
                Text("Make a read-only API token for the bucket - in Cloudflare, R2 \u{203A} Manage API tokens, Object Read only - and put it here. It is kept in this phone's Keychain, never synced to iCloud and never sent to your PC.\n\nThere is no live view with your PC off, and there cannot be: the camera is plugged into the PC. What this reads is what the PC already uploaded.")
                    .font(.footnote).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("Access key ID", text: $keyId)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret access key", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button(HUD.spaced("Save to the Keychain")) {
                    stored.remember(accessKeyId: keyId, secretAccessKey: secret)
                    keyId = ""
                    secret = ""
                    Task { await stored.refresh() }
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(keyId.isEmpty || secret.isEmpty)
            } else {
                Button(HUD.spaced("Forget the store")) { stored.leave() }
                    .buttonStyle(HUDButtonStyle())
            }
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
