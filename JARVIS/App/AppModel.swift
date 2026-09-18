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
    private var frameTimes: [Date] = []

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

    func connect() async {
        guard let pc else { link = .unpaired; return }
        if let client, await client.isOpen, link.isOnline { return }

        link = .connecting
        let client = BridgeClient(endpoint: pc.endpoint)
        await client.setHandlers(
            push: { message in Task { @MainActor in AppModel.shared.handlePush(message) } },
            close: { error in Task { @MainActor in AppModel.shared.dropped(error) } })

        do {
            let name = try await client.resume(deviceId: pc.deviceId, pinnedServerKey: pc.serverKey)
            self.client = client
            failures = 0
            link = .online(name)
            await refresh()
        } catch {
            await client.close()
            link = .offline(error.localizedDescription)
            if (error as? BridgeError)?.needsPairingAgain == true { return }
            scheduleReconnect()
        }
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

    private func session() async throws -> BridgeClient {
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
            let reply = try await session().approvedRequest("screen.start", reason: "Watch your PC's screen", ["display": display])
            if reply.kind == "done" {
                if liveDisplay != display { screenFrame = nil }
                liveDisplay = display
                frameTimes = []
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

    private func receiveFrame(_ message: BridgeMessage) {
        guard let display = (message.body["display"] as? NSNumber)?.intValue, display == liveDisplay,
              let jpeg = message.text("jpeg"), let data = Data(base64Encoded: jpeg), let image = UIImage(data: data) else { return }
        screenFrame = image
        let now = Date()
        frameTimes = frameTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
        screenFramesPerSecond = Double(frameTimes.count) / 2
    }

    private func handlePush(_ message: BridgeMessage) {
        if message.kind == "voice" { receiveVoice(message); return }
        if message.kind == "screen.frame" { receiveFrame(message); return }
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
