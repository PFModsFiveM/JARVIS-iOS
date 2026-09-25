import SwiftUI

/// Settings for the PC's pre-login service: the part of JARVIS that is there before anybody signs in.
///
/// Its own panel rather than a line in the PC one, because it is a second pairing with a second key
/// and pretending otherwise would make "forget" and "the key doesn't match" mean two things each.
struct BeforeSignInPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var machine = MachineLink.shared

    @State private var code = ""
    @State private var typedHost = ""
    @State private var pairing = false
    @State private var confirmForget = false

    var body: some View {
        HUDFrame(title: "Before sign-in") {
            if machine.isPaired {
                paired
            } else {
                unpaired
            }
        }
        .confirmationDialog("Forget the service?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { machine.forget() }
        }
    }

    @ViewBuilder
    private var paired: some View {
        if let report = machine.report {
            row("Machine", report.machine)
            row("Windows", report.described)
            row("JARVIS", report.desktopRunning ? "running" : "not running")
        } else {
            row("Last answer", machine.asking ? "asking…" : "none yet")
        }

        row("Key", machine.paired?.fingerprint ?? "-")

        if let problem = machine.problem {
            Text(problem).font(.footnote).foregroundStyle(HUD.amber)
        }

        Text("This is a separate key from the PC's, because a service that runs before anybody has signed in cannot open one sealed to your Windows account. It answers what the machine is doing and nothing else - it cannot be asked to run anything.")
            .font(.footnote).foregroundStyle(HUD.dim)

        Button(machine.asking ? "Asking…" : "Ask the machine") {
            Task { await machine.ask(force: true) }
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(machine.asking)

        Button("Forget the service") { confirmForget = true }
            .buttonStyle(HUDButtonStyle(tint: HUD.alert))
    }

    @ViewBuilder
    private var unpaired: some View {
        Text("Pair with the service and this phone can tell whether your PC is off, or on with nobody signed in, or locked - instead of only \u{201C}not answering\u{201D}.")
            .foregroundStyle(HUD.text)

        Text("On the PC, in an elevated PowerShell:")
            .font(.footnote).foregroundStyle(HUD.dim)

        Text("Jarvis.SystemService.exe --pair")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(HUD.accent)
            .textSelection(.enabled)

        TextField("ABC234", text: $code)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .foregroundStyle(HUD.accent)
            .onChange(of: code) { _, value in code = String(value.uppercased().prefix(6)) }

        DisclosureGroup("Type the PC's address instead") {
            TextField("192.168.1.20", text: $typedHost)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)

            Text("Only needed if this phone has never reached the PC at home; otherwise it already knows where the machine is.")
                .font(.footnote).foregroundStyle(HUD.dim)
        }
        .tint(HUD.accent)
        .foregroundStyle(HUD.text)

        if let digits = machine.pairingDigits {
            Text("\(digits.prefix(3)) \(digits.suffix(3))")
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundStyle(HUD.amber)
                .frame(maxWidth: .infinity)

            Text("These must be the digits the PC's console is showing. If they are not, answer no there - something is between this phone and your PC.")
                .font(.footnote).foregroundStyle(HUD.amber)
        }

        if let problem = machine.problem {
            Text(problem).font(.footnote).foregroundStyle(HUD.amber)
        }

        Button(pairing ? "Waiting for the PC" : "Pair with the service") {
            Task {
                pairing = true
                await machine.pair(code: code, host: typedHost)
                pairing = false
            }
        }
        .buttonStyle(HUDButtonStyle(filled: true))
        .disabled(pairing || code.count != 6 || model.pc == nil)
        .opacity(pairing || code.count != 6 || model.pc == nil ? 0.5 : 1)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(HUD.dim)
            Spacer()
            Text(value).foregroundStyle(HUD.text).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }
}
