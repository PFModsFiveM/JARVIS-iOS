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

    let wake = WakeListener()
    let voice = Voice()

    /// What the wake word is doing, mirrored here so the views watch this one object.
    @Published private(set) var wakePhase: WakeListener.Phase = .off

    private var client: BridgeClient?
    private var reconnect: Task<Void, Never>?
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
        if phase == .active {
            Task { await connect() }
        } else if phase == .background && !wake.running {
            // Without background audio iOS suspends the app anyway; close cleanly so the PC's count is right.
            Task { await disconnect() }
        }
    }

    private func dropped(_ error: Error?) {
        client = nil
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

        do {
            let reply = try await session().request("ask", ["text": request], timeout: 90)
            let answer = reply.kind == "answer" ? (reply.text("text") ?? "") : reply.message
            lines.append(ChatLine(speaker: reply.kind == "answer" ? .jarvis : .system, text: answer))
            if speakAnswers || spoken { voice.say(answer) }
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

    private func handlePush(_ message: BridgeMessage) {
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
