import Foundation
import Network
import SwiftUI
import UIKit

struct ChatLine: Identifiable, Equatable {
    enum Speaker { case you, jarvis, system }
    let id = UUID()
    let speaker: Speaker
    let text: String
    let at = Date()
}

/// The Security Protocol as the PC reports it.
struct SecuritySnapshot: Equatable {
    struct Challenge: Equatable {
        var eventId: String
        var attempts: Int
        var maxAttempts: Int
        var remaining: Int
        var mode: String
    }

    var state: String
    var description: String
    var testing: Bool
    var learned: Int
    var needed: Int
    var challenge: Challenge?

    init?(_ body: [String: Any]?) {
        guard let body, let state = body["state"] as? String else { return nil }
        self.state = state
        description = body["description"] as? String ?? state
        testing = body["testing"] as? Bool ?? false
        learned = body["learned"] as? Int ?? 0
        needed = body["needed"] as? Int ?? 0
        if let c = body["challenge"] as? [String: Any] {
            challenge = Challenge(eventId: c["eventId"] as? String ?? "", attempts: c["attempts"] as? Int ?? 0,
                                  maxAttempts: c["maxAttempts"] as? Int ?? 0, remaining: c["remaining"] as? Int ?? 0,
                                  mode: c["mode"] as? String ?? "")
        }
    }

    var isOff: Bool { state == "Disabled" || state == "unavailable" }
    var isChallenge: Bool { challenge != nil || state == "Challenge" }
}

/// Everything the screens show and every action they take.
@MainActor
final class AppModel: ObservableObject {
    enum Link: Equatable {
        case unpaired
        case offline(String?)
        case connecting
        case online(String)

        var isOnline: Bool { if case .online = self { return true } else { return false } }
    }

    static let shared = AppModel()

    @Published var pc: PairedPC? = PairedPC.load()
    @Published private(set) var link: Link = .unpaired
    @Published private(set) var status: [String: Any] = [:]
    @Published private(set) var security: SecuritySnapshot?
    @Published private(set) var lines: [ChatLine] = []
    @Published private(set) var thinking = false
    @Published var toast: String?
    @Published var pairingDigits: String?

    @Published var speakAnswers = UserDefaults.standard.object(forKey: "speakAnswers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "speakAnswers") }
    }
    @Published private(set) var wakeWordOn = UserDefaults.standard.bool(forKey: "wakeWordOn") {
        didSet { UserDefaults.standard.set(wakeWordOn, forKey: "wakeWordOn") }
    }
    /// Answers in JARVIS's own voice, rendered on the PC. Off reads them out in the phone's voice.
    @Published var usePCVoice = UserDefaults.standard.object(forKey: "usePCVoice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(usePCVoice, forKey: "usePCVoice") }
    }
    /// The circle, the face, or neither, at the top of the home screen.
    @Published var centrepiece = Centrepiece(rawValue: UserDefaults.standard.string(forKey: "centrepiece") ?? "") ?? .circle {
        didSet { UserDefaults.standard.set(centrepiece.rawValue, forKey: "centrepiece") }
    }
    /// The face looks away to think, meets your eyes while listening, sleeps offline. Off holds it neutral; the lips still move.
    @Published var facialState = UserDefaults.standard.object(forKey: "facialState") as? Bool ?? true {
        didSet { UserDefaults.standard.set(facialState, forKey: "facialState") }
    }
    @Published private(set) var speaking = false
    /// A jarvis:// link from Siri or Shortcuts for the root view to act on once the app is on screen.
    @Published var pendingLink: URL?
    @Published private(set) var awaitingVoice = false

    /// Live view: the PC's displays, the one being watched, and its latest frame.
    struct ScreenDisplayInfo: Identifiable, Equatable {
        let index: Int
        let name: String
        let width: Int
        let height: Int
        let primary: Bool
        var id: Int { index }
    }
    @Published private(set) var screenDisplays: [ScreenDisplayInfo] = []
    @Published private(set) var liveDisplay: Int?
    @Published private(set) var screenFrame: UIImage?
    @Published private(set) var screenFramesPerSecond = 0.0
    /// The phone has control of the PC's keyboard and mouse on this connection (Face ID once).
    @Published private(set) var controlling = false
    /// The PC's sound is playing on the phone.
    @Published private(set) var hearingPC = false
    /// The last photo from the PC's camera, asked for or sent when the Security Protocol challenged someone.
    @Published var cameraPhoto: UIImage?
    @Published private(set) var challengePhoto: UIImage?
    private let pcAudio = PCAudioPlayer()
    private var frameTimes: [Date] = []
    private var newestFrame = -1
    let network = NetworkWatch()

    let wake = WakeListener()
    let voice = Voice()

    /// What the wake word is doing, mirrored here so the views watch this one object.
    @Published private(set) var wakePhase: WakeListener.Phase = .off

    private var client: BridgeClient?
    private var reconnect: Task<Void, Never>?

    /// JARVIS's voice for an answer, arriving in parts after the words. Count 0 means the PC could not render it.
    private struct VoiceParts {
        var count: Int
        var parts: [Int: Data] = [:]
        var mouth: [Float] = []
    }
    private var voiceParts: [String: VoiceParts] = [:]
    private var voiceWait: (id: String, text: String, timeout: Task<Void, Never>)?
    private var failures = 0
    private var foreground = true

    private init() {
        link = pc == nil ? .unpaired : .offline(nil)
        wake.onCommand = { [weak self] command in
            Task { await self?.ask(command, spoken: true) }
        }
        wake.onPhase = { [weak self] phase in self?.wakePhase = phase }
        voice.onSpeaking = { [weak self] speaking in
            // JARVIS must not hear itself answering.
            self?.wake.paused = speaking
            self?.speaking = speaking
        }
    }

    var pcName: String {
        if case .online(let name) = link { return name }
        return (status["machine"] as? String) ?? pc?.serviceName ?? pc?.host ?? "PC"
    }

    // MARK: connection

    /// How the phone is reaching the PC right now: at home, or through the away-from-home address.
    @Published private(set) var route: String?

    /// Home first, then away-from-home - or the other way round on mobile data, where the home address cannot answer.
    func connect() async {
        guard let pc else { link = .unpaired; return }
        if let client, await client.isOpen, link.isOnline { return }

        link = .connecting
        var routes: [(name: String, endpoint: NWEndpoint)] = [("Home network", pc.endpoint)]
        if let remote = pc.remoteEndpoint {
            if network.cellular { routes.insert(("Away from home", remote), at: 0) } else { routes.append(("Away from home", remote)) }
        }

        var lastError: Error = BridgeError.closed
        for route in routes {
            let client = BridgeClient(endpoint: route.endpoint)
            await client.setHandlers(
                push: { message in Task { @MainActor in AppModel.shared.handlePush(message) } },
                close: { error in Task { @MainActor in AppModel.shared.dropped(error) } })

            do {
                let name = try await client.resume(deviceId: pc.deviceId, pinnedServerKey: pc.serverKey)
                self.client = client
                failures = 0
                ControlModel.shared.connectionChanged()
                controlling = false
                self.route = route.name
                link = .online(name)
                await refresh()
                return
            } catch {
                await client.close()
                lastError = error
                // A PC that no longer knows this phone will not know it by another route either.
                if (error as? BridgeError)?.needsPairingAgain == true {
                    link = .offline(error.localizedDescription)
                    return
                }
            }
        }

        route = nil
        link = .offline(lastError.localizedDescription)
        scheduleReconnect()
    }

    /// Saves the PC's away-from-home address (Tailscale), or clears it with an empty string.
    func setRemoteHost(_ host: String) {
        guard var paired = pc else { return }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        paired.remoteHost = trimmed.isEmpty ? nil : trimmed
        paired.save()
        pc = paired
    }

    func disconnect() async {
        reconnect?.cancel()
        await client?.close()
        client = nil
        if pc != nil { link = .offline(nil) }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        // Nobody is looking at the screen from a pocket.
        if phase != .active, liveDisplay != nil { Task { await stopLive() } }
        if phase == .active {
            Task { await connect() }
        } else if phase == .background && !wake.running {
            // Without background audio iOS suspends the app anyway; close cleanly so the PC's count is right.
            Task { await disconnect() }
        }
    }

    private func dropped(_ error: Error?) {
        client = nil
        liveDisplay = nil
        controlling = false
        if hearingPC { pcAudio.stop(); hearingPC = false }
        guard pc != nil else { return }
        link = .offline(error?.localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        guard foreground || wake.running else { return }
        failures += 1
        let delay = min(30.0, pow(2.0, Double(min(failures, 5))))
        reconnect = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await connect()
        }
    }

    func session() async throws -> BridgeClient {
        if let client, await client.isOpen { return client }
        await connect()
        guard let client else { throw BridgeError.closed }
        return client
    }

    func refresh() async {
        guard let client = try? await session() else { return }
        if let reply = try? await client.request("status") { status = reply.body }
        if let reply = try? await client.request("security.status") { security = SecuritySnapshot(reply.body) }
    }

    // MARK: asking

    func ask(_ text: String, spoken: Bool = false) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        lines.append(ChatLine(speaker: .you, text: request))
        thinking = true
        defer { thinking = false }

        // A new question makes whatever was still coming for the last one stale.
        cancelVoiceWait()
        voice.stop()

        do {
            let reply = try await session().request("ask", ["text": request], timeout: 90)
            let answer = reply.kind == "answer" ? (reply.text("text") ?? "") : reply.message
            lines.append(ChatLine(speaker: reply.kind == "answer" ? .jarvis : .system, text: answer))
            LiveActivity.shared.answer = answer
            if speakAnswers || spoken {
                if usePCVoice, reply.kind == "answer", reply.body["voice"] as? Bool == true {
                    expectVoice(for: reply.id, fallback: answer)
                } else {
                    voice.say(answer)
                }
            }
        } catch {
            lines.append(ChatLine(speaker: .system, text: error.localizedDescription))
        }
    }

    // MARK: security

    func securityAction(_ action: String) async {
        await run { try await $0.request("security.\(action)") }
    }

    /// Stands the protocol down - Face ID first.
    func standDown() async {
        await run { try await $0.approvedRequest("security.standDown", reason: "Stand down the Security Protocol on your PC") }
    }

    /// "It's me": answers the challenge on the PC - Face ID first.
    func approveChallenge() async {
        await run { try await $0.approvedRequest("security.approve", reason: "Confirm it's you at your PC") }
    }

    /// "That isn't me": locks the PC at once. No Face ID - making things safer needs none.
    func denyChallenge() async {
        await run { try await $0.request("security.deny") }
    }

    private func run(_ action: (BridgeClient) async throws -> BridgeMessage) async {
        do {
            let reply = try await action(try await session())
            if let snapshot = SecuritySnapshot(reply.object("security")) { security = snapshot }
            toast = reply.message.prefix(1).uppercased() + reply.message.dropFirst()
            UINotificationFeedbackGenerator().notificationOccurred(reply.kind == "done" ? .success : .warning)
            if reply.object("security") == nil { await refresh() }
        } catch {
            toast = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: JARVIS's voice

    /// The words are in; the voice follows as "voice" pushes. Wait a little for it, then read the words out instead.
    private func expectVoice(for id: String, fallback: String) {
        cancelVoiceWait()
        if let arrived = voiceParts[id], arrived.count == 0 {
            voiceParts[id] = nil
            voice.say(fallback)
            return
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.voiceUnavailable(id)
        }
        voiceWait = (id, fallback, timeout)
        awaitingVoice = true
        playVoiceIfComplete(id)
    }

    private func receiveVoice(_ message: BridgeMessage) {
        guard let id = message.text("for") else { return }
        let count = (message.body["count"] as? NSNumber)?.intValue ?? 0
        let index = (message.body["index"] as? NSNumber)?.intValue ?? -1

        guard count > 0, index >= 0, index < count, let audio = message.text("audio"), let data = Data(base64Encoded: audio) else {
            voiceParts[id] = VoiceParts(count: 0)
            voiceUnavailable(id)
            return
        }

        // Only the answer being waited for, or one whose words have not arrived yet, is worth keeping.
        let waiting = voiceWait?.id
        voiceParts = voiceParts.filter { $0.key == id || $0.key == waiting }
        var entry = voiceParts[id] ?? VoiceParts(count: count)
        entry.parts[index] = data
        if let mouth = message.body["mouth"] as? [NSNumber] { entry.mouth = mouth.map { $0.floatValue } }
        voiceParts[id] = entry
        playVoiceIfComplete(id)
    }

    private func playVoiceIfComplete(_ id: String) {
        guard let wait = voiceWait, wait.id == id, let entry = voiceParts[id], entry.count > 0, entry.parts.count == entry.count else { return }
        var wav = Data()
        for index in 0..<entry.count {
            guard let part = entry.parts[index] else { return }
            wav.append(part)
        }
        voiceParts[id] = nil
        cancelVoiceWait()
        if !voice.play(wav: wav, mouth: entry.mouth) { voice.say(wait.text) }
    }

    private func voiceUnavailable(_ id: String) {
        guard let wait = voiceWait, wait.id == id else { return }
        voiceParts[id] = nil
        cancelVoiceWait()
        voice.say(wait.text)
    }

    private func cancelVoiceWait() {
        voiceWait?.timeout.cancel()
        voiceWait = nil
        awaitingVoice = false
    }

    // MARK: what the circle and the face show

    var visualState: JarvisVisualState {
        if security?.isChallenge == true { return .securityAlert }
        if speaking { return .speaking }
        if !link.isOnline { return .offline }
        if thinking || awaitingVoice { return .thinking }
        if case .hearing = wakePhase { return .listening }
        return .idle
    }

    /// 0-1: JARVIS's voice while it speaks, the microphone while it listens.
    func centreLevel() -> Float {
        if speaking { return voice.level }
        if case .hearing = wakePhase { return wake.level }
        return 0
    }

    func centreMouth() -> [MouthFrame]? { voice.takeMouth() }

    // MARK: live view

    func loadDisplays() async {
        guard let reply = try? await session().request("screen.displays"), reply.kind == "screen.displays",
              let list = reply.body["displays"] as? [[String: Any]] else { return }
        screenDisplays = list.map { d in
            ScreenDisplayInfo(index: (d["index"] as? NSNumber)?.intValue ?? 0, name: d["name"] as? String ?? "Display",
                              width: (d["width"] as? NSNumber)?.intValue ?? 0, height: (d["height"] as? NSNumber)?.intValue ?? 0,
                              primary: d["primary"] as? Bool ?? false)
        }
    }

    /// Face ID, then the PC starts sending the display. Watching only: nothing here reaches the PC's keyboard or mouse.
    func startLive(_ display: Int) async {
        do {
            // Face ID once per connection: after the first approval the PC lets this connection switch displays freely.
            let client = try await session()
            let body: [String: Any] = ["display": display, "network": network.cellular ? "cellular" : "wifi"]
            var reply = try await client.request("screen.start", body)
            if reply.kind != "done" {
                reply = try await client.approvedRequest("screen.start", reason: "Watch your PC's screen", body)
            }
            if reply.kind == "done" {
                if liveDisplay != display { screenFrame = nil }
                liveDisplay = display
                frameTimes = []
                newestFrame = -1
            } else {
                toast = reply.message
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func stopLive() async {
        liveDisplay = nil
        screenFramesPerSecond = 0
        _ = try? await client?.request("screen.stop")
    }

    /// Decoded off the main thread, so a 20-frame-a-second stream never makes the app stutter; a frame that finishes
    /// decoding after a newer one is dropped.
    private func receiveFrame(_ message: BridgeMessage) {
        guard let display = (message.body["display"] as? NSNumber)?.intValue, display == liveDisplay,
              let sequence = (message.body["sequence"] as? NSNumber)?.intValue,
              let jpeg = message.text("jpeg"), let data = Data(base64Encoded: jpeg) else { return }

        Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data)?.preparingForDisplay() else { return }
            await MainActor.run {
                let model = AppModel.shared
                guard model.liveDisplay == display, sequence > model.newestFrame || sequence == 0 else { return }
                model.newestFrame = sequence
                model.screenFrame = image
                let now = Date()
                model.frameTimes = model.frameTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
                model.screenFramesPerSecond = Double(model.frameTimes.count) / 2
            }
        }
    }

    // MARK: the PC's sound and camera

    /// Face ID once per connection (the same grant as watching), then the PC's speakers play here.
    func toggleSound() async {
        if hearingPC {
            hearingPC = false
            pcAudio.stop()
            _ = try? await client?.request("audio.stop")
            return
        }
        do {
            let client = try await session()
            var reply = try await client.request("audio.start")
            if reply.kind != "done" { reply = try await client.approvedRequest("audio.start", reason: "Hear your PC's sound") }
            if reply.kind == "done" {
                pcAudio.start(rate: 24000)
                hearingPC = true
            } else {
                toast = reply.message
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func takeCameraPhoto() async {
        do {
            let client = try await session()
            var reply = try await client.request("camera", timeout: 20)
            if reply.kind == "failed", reply.message.contains("Face ID") {
                reply = try await client.approvedRequest("camera", reason: "See through your PC's camera")
            }
            if reply.kind == "camera", let jpeg = reply.text("jpeg"), let data = Data(base64Encoded: jpeg) {
                cameraPhoto = UIImage(data: data)
            } else {
                toast = reply.message
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    private func receiveSecurityPhoto(_ message: BridgeMessage) {
        guard let jpeg = message.text("jpeg"), let data = Data(base64Encoded: jpeg), let image = UIImage(data: data) else { return }
        challengePhoto = image
        Alerts.photo(title: "Who's at \(pcName)", body: "The Security Protocol has challenged them. This is what the PC's camera sees.", jpeg: data)
    }

    // MARK: remote control

    /// Face ID once; the PC then takes this connection's clicks and keys until it disconnects.
    func takeControl() async {
        do {
            let reply = try await session().approvedRequest("control.start", reason: "Control your PC from this iPhone")
            controlling = reply.kind == "done"
            if !controlling { toast = reply.message }
            UINotificationFeedbackGenerator().notificationOccurred(controlling ? .success : .warning)
        } catch {
            toast = error.localizedDescription
        }
    }

    func releaseControl() { controlling = false }

    /// Clicks, keys and scrolls are sent without waiting for one another's answers, so the pointer keeps up with the
    /// finger; a refusal still comes back as a toast.
    func input(_ kind: String, _ body: [String: Any]) {
        guard controlling else { return }
        var payload = body
        if payload["display"] == nil, let display = liveDisplay { payload["display"] = display }
        Task {
            guard let client = try? await session() else { return }
            if let reply = try? await client.request(kind, payload), reply.kind == "failed" { toast = reply.message }
        }
    }

    // MARK: trackpad

    private var pendingMove = CGSize.zero
    private var moveFlush: Task<Void, Never>?

    /// Trackpad movement, coalesced: finger motion arrives many times a frame, the PC hears at most ~30 moves a second.
    func moveBy(_ delta: CGSize) {
        guard controlling else { return }
        pendingMove.width += delta.width
        pendingMove.height += delta.height
        guard moveFlush == nil else { return }
        moveFlush = Task {
            try? await Task.sleep(nanoseconds: 33_000_000)
            let move = pendingMove
            pendingMove = .zero
            moveFlush = nil
            let dx = Int(move.width.rounded()), dy = Int(move.height.rounded())
            if dx != 0 || dy != 0 { input("input.moveBy", ["dx": dx, "dy": dy]) }
        }
    }

    /// The network changed under a running stream: restart it with the right quality for the new one.
    func networkChanged() {
        guard let display = liveDisplay else { return }
        Task { await startLive(display) }
    }

    /// Something JARVIS said on its own - a reminder, a finished task, a question. In the conversation while the app
    /// is open; as a notification while it runs in the background.
    private func receiveNotice(_ message: BridgeMessage) {
        guard let text = message.text("text"), !text.isEmpty else { return }
        let title = message.text("title") ?? "JARVIS"
        lines.append(ChatLine(speaker: .jarvis, text: text))
        if foreground {
            toast = "\(title): \(text)"
        } else {
            Alerts.post(title: title, body: text)
        }
    }

    private func handlePush(_ message: BridgeMessage) {
        if message.kind == "voice" { receiveVoice(message); return }
        if message.kind == "screen.frame" { receiveFrame(message); return }
        if message.kind == "file.data" { ControlModel.shared.receiveFileData(message); return }
        if message.kind == "notice" { receiveNotice(message); return }
        if message.kind == "audio.frame" {
            if hearingPC, let pcm = message.text("pcm").flatMap({ Data(base64Encoded: $0) }) { pcAudio.play(pcm) }
            return
        }
        if message.kind == "security.photo" { receiveSecurityPhoto(message); return }
        if message.kind == "screen.ended" {
            liveDisplay = nil
            screenFramesPerSecond = 0
            toast = message.text("reason") ?? "Live view ended."
            return
        }
        guard message.kind == "security.event" else { return }
        let before = security
        if let snapshot = SecuritySnapshot(message.object("security")) { security = snapshot }

        if message.text("to") == "Challenge", before?.isChallenge != true {
            Alerts.challenge(pc: pcName, testing: security?.testing == true)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else if message.text("to") == "LockingWindows" {
            Alerts.post(title: "\(pcName) is locking", body: "The challenge wasn't answered, so Windows is being locked.")
        }
    }

    // MARK: pairing

    func pair(endpoint: NWEndpoint, serviceName: String?, host: String?, port: UInt16, code: String) async {
        pairingDigits = nil
        let client = BridgeClient(endpoint: endpoint)

        do {
            let result = try await client.pair(code: code, deviceName: UIDevice.current.name) { digits in
                Task { @MainActor in AppModel.shared.pairingDigits = digits }
            }
            let paired = PairedPC(deviceId: result.deviceId, serverKey: result.serverKey, serviceName: serviceName, host: host, port: port)
            paired.save()
            pc = paired
            pairingDigits = nil
            toast = "Paired. This PC's key is \(paired.fingerprint)."
            await connect()
        } catch {
            await client.close()
            pairingDigits = nil
            toast = error.localizedDescription
        }
    }

    func forget() async {
        await disconnect()
        PairedPC.forget()
        pc = nil
        status = [:]
        security = nil
        link = .unpaired
    }

    /// From the widget or Control Centre: listen for one request without the wake word, and send it when the speaker
    /// stops - the same as holding the button for as long as they talk.
    func listenOnce() async {
        await holdToTalk(true)
        var quiet = 0
        var heardSomething = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard case .hearing(let words) = wakePhase else { return }
            if !words.isEmpty { heardSomething = true }
            quiet = wake.level < 0.08 ? quiet + 1 : 0
            // About 1.5 s of quiet after some words, or 6 s of nothing at all.
            if (heardSomething && quiet >= 6) || (!heardSomething && quiet >= 24) { break }
        }
        await holdToTalk(false)
    }

    /// Hold to talk: the microphone listens while the button is down and asks JARVIS when it is let go.
    func holdToTalk(_ down: Bool) async {
        if down {
            voice.stop()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            do {
                try await wake.beginHold()
            } catch {
                toast = error.localizedDescription
            }
        } else {
            wake.endHold()
        }
    }

    func setWakeWord(_ on: Bool) async {
        wakeWordOn = on
        if on {
            do {
                try await wake.start()
            } catch {
                wakeWordOn = false
                toast = error.localizedDescription
            }
        } else {
            wake.stop()
        }
    }
}
