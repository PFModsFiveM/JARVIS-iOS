import SwiftUI

/// The reactor, the link to the PC, the wake word, and the conversation.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var typed = ""
    @FocusState private var typing: Bool
    @State private var holding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            inputBar
        }
        .background(HUD.background.ignoresSafeArea())
    }

    private var linkColor: Color {
        switch model.link {
        case .online: return HUD.accent
        case .connecting: return HUD.dim
        default: return HUD.amber
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if model.centrepiece != .none {
                // Tap to switch between the circle and the face, as "show the face" does on the PC.
                CentrepieceView(kind: model.centrepiece, state: model.visualState,
                                level: { model.centreLevel() }, mouth: { model.centreMouth() },
                                facialState: model.facialState)
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.centrepiece = model.centrepiece == .circle ? .face : .circle }
                    .accessibilityLabel(model.centrepiece == .circle ? "JARVIS circle. Tap for the face." : "JARVIS face. Tap for the circle.")
            }
            HStack(alignment: .center, spacing: 16) {
                if model.centrepiece == .none {
                    Reactor(color: model.security?.isChallenge == true ? HUD.alert : linkColor, active: model.wakePhase != .off)
                        .frame(width: 84, height: 84)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.pcName.uppercased())
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(HUD.text)
                        .lineLimit(1)
                    HUDLabel(text: linkText, color: linkColor)
                    if let security = model.security {
                        HUDLabel(text: "Security: \(security.description)", color: security.isChallenge ? HUD.alert : HUD.dim)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            Toggle(isOn: Binding(get: { model.wakeWordOn }, set: { on in Task { await model.setWakeWord(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen for \u{201C}Jarvis\u{201D}").foregroundStyle(HUD.text)
                    Text(wakeText).font(.caption).foregroundStyle(HUD.dim).lineLimit(1)
                }
            }
            .tint(HUD.accent)

            if model.security?.isChallenge == true {
                ChallengeBanner()
            }
        }
        .padding(16)
        .background(HUD.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(HUD.accent.opacity(0.3)), alignment: .bottom)
    }

    private var linkText: String {
        switch model.link {
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .offline(let why): return why == nil ? "Offline" : "Offline - tap to retry"
        case .unpaired: return "Not paired"
        }
    }

    private var wakeText: String {
        switch model.wakePhase {
        case .off: return "Off. Say \u{201C}Hey Siri, ask JARVIS\u{201D} any time."
        case .waiting: return "Listening on this iPhone, even when locked"
        case .hearing(let words): return words.isEmpty ? "Yes?" : words
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.lines.isEmpty {
                        Text("Ask anything you'd ask JARVIS at your desk - it runs on your PC and answers here.")
                            .foregroundStyle(HUD.dim)
                            .padding(.top, 30)
                    }
                    ForEach(model.lines) { line in
                        Bubble(line: line).id(line.id)
                    }
                    if model.thinking {
                        HStack(spacing: 8) {
                            ProgressView().tint(HUD.accent)
                            HUDLabel(text: "Working")
                        }
                        .id("thinking")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.lines.count) { _, _ in
                guard let last = model.lines.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onTapGesture {
                typing = false
                if case .offline = model.link { Task { await model.connect() } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask JARVIS", text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .foregroundStyle(HUD.text)
                .padding(10)
                .background(HUD.panel)
                .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
                .submitLabel(.send)
                .onSubmit(send)
            // Hold to talk: press, speak, let go.
            Image(systemName: holding ? "waveform" : "mic.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(holding ? HUD.background : HUD.accent)
                .frame(width: 42, height: 42)
                .background(holding ? HUD.accent : HUD.accent.opacity(0.12))
                .overlay(Rectangle().stroke(HUD.accent.opacity(0.5), lineWidth: 1))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        Task { await model.holdToTalk(true) }
                    }
                    .onEnded { _ in
                        holding = false
                        Task { await model.holdToTalk(false) }
                    })
                .accessibilityLabel("Hold to talk")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(HUD.background)
                    .frame(width: 42, height: 42)
                    .background(HUD.accent)
            }
            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(HUD.background)
    }

    private func send() {
        let text = typed
        typed = ""
        Task { await model.ask(text) }
    }
}

private struct Bubble: View {
    let line: ChatLine

    var body: some View {
        HStack {
            if line.speaker == .you { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HUDLabel(text: line.speaker == .you ? "You" : line.speaker == .jarvis ? "Jarvis" : "System",
                         color: line.speaker == .system ? HUD.amber : HUD.dim)
                Text(line.text)
                    .foregroundStyle(line.speaker == .system ? HUD.amber : HUD.text)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(line.speaker == .you ? HUD.accent.opacity(0.12) : HUD.panel)
            .overlay(Rectangle().stroke((line.speaker == .you ? HUD.accent : HUD.dim).opacity(0.35), lineWidth: 1))
            if line.speaker != .you { Spacer(minLength: 40) }
        }
    }
}

/// Shown wherever the app is while a challenge is up on the PC.
struct ChallengeBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                Text(model.security?.testing == true ? "TEST CHALLENGE ON THE PC" : "SOMEONE IS AT YOUR PC")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                Spacer()
                if let challenge = model.security?.challenge {
                    Text("\(challenge.attempts)/\(challenge.maxAttempts)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(HUD.alert)
            HStack(spacing: 10) {
                Button("It's me") { Task { await model.approveChallenge() } }
                    .buttonStyle(HUDButtonStyle(tint: HUD.good))
                Button("Lock PC") { Task { await model.denyChallenge() } }
                    .buttonStyle(HUDButtonStyle(tint: HUD.alert, filled: true))
            }
        }
        .padding(12)
        .background(HUD.alert.opacity(0.1))
        .overlay(Rectangle().stroke(HUD.alert, lineWidth: 1.5))
    }
}
