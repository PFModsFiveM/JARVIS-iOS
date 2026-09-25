import AVFoundation
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

    /// Bonjour, kept running while the app is open rather than only on the pairing screen.
    ///
    /// Seeing the PC on this network is proof the phone is at home, which is better evidence than
    /// any guess from the interface type - and it is the one candidate that still works when every
    /// address the PC has has changed. It costs nothing when there is nothing to find.
    let browser = PCBrowser()

    let wake = WakeListener()
    let voice = Voice()

    /// Where the phone is, for the PC that cannot see it.
    ///
    /// Off until the owner turns it on in Settings, because it asks for the always-on location
    /// permission and that is not a thing to take quietly. It keeps what it cannot send, so a walk
    /// taken while the PC was asleep is still a walk the PC learns about afterwards.
    lazy var whereabouts = LocationReporter { [weak self] kind, body in
        guard let self else { throw BridgeError.closed }

        _ = try await self.session().request(kind, body)
    }

    /// What the wake word is doing, mirrored here so the views watch this one object.
    @Published private(set) var wakePhase: WakeListener.Phase = .off

    /// Whether the only way out is mobile data, mirrored here for the same reason.
    ///
    /// Six places across the views read this to decide what to show and what to try. They were
    /// reading it off `network`, which is a different observable object - so they redrew only
    /// because the change also wrote a line to `connectionLog`, which is published and which they
    /// do watch. That worked, and it worked by accident: tidying away one log line would have left
    /// every "Wi-Fi or cellular" label in the app showing yesterday's answer, including the one on
    /// the diagnostics screen somebody would be reading precisely because something was wrong.
    @Published private(set) var onCellular = false

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

    // MARK: the PC, awake or asleep

    /// What the PC page shows. Every state a person would recognise, including the ones where the
    /// bridge cannot possibly be up - because a PC that is asleep is the case this whole thing
    /// exists for, and an app that can only say "offline" then is an app with a dead page in it.
    enum DeviceState: Equatable {
        /// Not reachable, and nothing set up to wake it.
        case offline(String?)
        /// Not reachable, and this phone can send a wake request from where it is.
        case wakeAvailable
        /// The button has been pressed; the packets have not left yet.
        case wakeRequested
        /// The packets left. Nothing has answered yet, and nothing claims the PC is awake.
        case waking(sent: String, seconds: Int)
        /// Something is answering; the handshake is running.
        case bridgeConnecting
        case online(String)
        /// The wake request went out and the PC never appeared.
        case wakeTimedOut(String)
        case connectionFailed(String)
        case unpaired

        var headline: String {
            switch self {
            case .offline, .wakeAvailable: return "OFFLINE"
            case .wakeRequested, .waking: return "WAKING..."
            case .bridgeConnecting: return "CONNECTING"
            case .online: return "ONLINE"
            case .wakeTimedOut: return "NO ANSWER"
            case .connectionFailed: return "OFFLINE"
            case .unpaired: return "NOT PAIRED"
            }
        }

        /// What the state says under the headline. Never a claim that the PC is awake.
        var detail: String {
            switch self {
            case .offline(let why): return why ?? "JARVIS isn't answering."
            case .wakeAvailable: return "JARVIS isn't answering. It can be woken from here."
            case .wakeRequested: return "Sending the wake request..."
            case .waking(let sent, let seconds):
                return seconds > 0 ? "Wake request sent to \(sent)\nWaiting for JARVIS... \(seconds)s" : "Wake request sent to \(sent)\nWaiting for JARVIS..."
            case .bridgeConnecting: return "Connecting..."
            case .online: return "JARVIS connected"
            case .wakeTimedOut(let sent): return "The wake request was sent to \(sent), but JARVIS never answered."
            case .connectionFailed(let why): return why
            case .unpaired: return "Pair with a PC to begin."
            }
        }

        var canWake: Bool {
            switch self {
            case .wakeAvailable, .offline, .wakeTimedOut, .connectionFailed: return true
            default: return false
            }
        }

        var isOnline: Bool { if case .online = self { return true } else { return false } }
    }

    /// The PC as the device page shows it: the link, plus whether waking is possible from here.
    var device: DeviceState {
        if let wake = wakeState { return wake }
        switch link {
        case .unpaired: return .unpaired
        case .online(let name): return .online(name)
        case .connecting: return .bridgeConnecting
        case .offline(let why):
            return wakeProfile.usable || wakeProfile.reachableRemotely ? .wakeAvailable : .offline(why)
        }
    }

    /// Set while a wake is in flight, and cleared the moment the bridge comes up or the wait ends.
    @Published private(set) var wakeState: DeviceState?

    /// What this phone knows about waking the PC. Told to it by the PC; never typed unless the owner insists.
    @Published var wakeProfile = WakeProfile.load()

    /// How long to wait for the PC to answer after a wake request.
    ///
    /// Ninety seconds. A machine coming out of sleep is on the network in five to fifteen; one
    /// coming from hibernate or a cold start takes longer, and Tailscale needs a moment after that
    /// to reconnect. Long enough not to give up on a working wake, short enough that a wake that
    /// did nothing does not leave the page saying "waiting" for ever.
    static let wakeWindow = 90

    private let wakeService = WakeOnLanService()
    private var waking: Task<Void, Never>?

    /// Sends a wake request, then keeps trying the bridge until the PC answers or the window ends.
    ///
    /// The two halves are deliberately separate. Wake-on-LAN cannot tell whether it worked - UDP is
    /// not acknowledged and there is no reply in the protocol - so "sent" is all the first half ever
    /// claims, and the second half is what actually establishes that the PC is awake: it answered.
    func wakePC() {
        guard waking == nil else { return }

        // The task inherits this class's actor, so everything inside it - including clearing the
        // handle when it finishes - runs on the main actor like the rest of the model.
        waking = Task { [weak self] in
            guard let self else { return }
            await self.wakeAndWait()
            self.waking = nil
        }
    }

    private func wakeAndWait() async {
        wakeState = .wakeRequested
        var profile = wakeProfile
        profile.lastAttempt = Date()
        profile.save()
        wakeProfile = profile

        let onCellular = network.cellular
        let outcome = await wakeService.wake(profile, cellular: onCellular)

        guard outcome.sent else {
            note("wake: \(outcome.because)")
            wakeState = .connectionFailed(outcome.because)
            return
        }

        note("wake: sent \(outcome.packets) packets to \(outcome.destination)")
        wakeState = .waking(sent: outcome.destination, seconds: 0)

        // Try the bridge repeatedly rather than once at the end: the PC may be up in five seconds,
        // and making somebody wait ninety for a page to notice is its own kind of broken.
        let started = Date()
        while Date().timeIntervalSince(started) < Double(Self.wakeWindow) {
            if Task.isCancelled { wakeState = nil; return }

            await connect()

            if link.isOnline {
                let took = Date().timeIntervalSince(started)
                note(String(format: "wake: %@ answered after %.1f s", pcName, took))
                wakeState = nil
                return
            }

            try? await Task.sleep(for: .seconds(3))
            wakeState = .waking(sent: outcome.destination, seconds: Int(Date().timeIntervalSince(started)))
        }

        note("wake: no answer after \(Self.wakeWindow) s")
        wakeState = .wakeTimedOut(outcome.destination)
    }

    /// What JARVIS says when asked to wake the PC. Never that it is awake - only that it was asked.
    func wakeAnswer() -> String {
        let name = wakeProfile.deviceName.isEmpty ? "your PC" : wakeProfile.deviceName

        if !wakeProfile.enabled { return "Waking \(name) is switched off, sir." }
        if wakeProfile.mac == nil {
            return "I don't know \(name)'s network card yet, sir. Connect to it once at home and it will tell me."
        }
        if WakeOnLanService.strategies(for: wakeProfile, cellular: network.cellular).isEmpty {
            return "I can only wake \(name) from home, sir - there's no way in from outside set up yet."
        }

        return "Sending the wake request now, sir. I'll connect as soon as \(name) answers."
    }

    /// Clears a finished wake so the page goes back to the ordinary states.
    func dismissWake() {
        waking?.cancel()
        waking = nil
        wakeState = nil
    }

    /// What the PC said about itself, saved so that being away from home needs nothing typed.
    ///
    /// Called after every successful connection. The PC knows its own addresses and its own card
    /// exactly; this channel has already proved which PC it is and is encrypted; so the PC says and
    /// this saves. Nothing here is a secret - an address is not a key.
    private func learnNetwork(_ body: [String: Any]) {
        guard var paired = pc else { return }

        let endpoints = (body["endpoints"] as? [[String: Any]]) ?? []
        let hosts = { (kind: String) in
            endpoints.filter { ($0["kind"] as? String) == kind }.compactMap { $0["host"] as? String }
        }

        let remote = hosts("private"), local = hosts("local")
        if !remote.isEmpty { paired.remoteHosts = remote }
        if !local.isEmpty { paired.localHosts = local }
        if let port = body["port"] as? Int, let port = UInt16(exactly: port), port > 0 { paired.port = port }
        paired.save()
        pc = paired

        if let wake = body["wake"] as? [String: Any] {
            var profile = wakeProfile
            profile.deviceName = (body["machine"] as? String) ?? profile.deviceName
            if let mac = MacAddress(wake["mac"] as? String) { profile.mac = mac }
            if let broadcast = wake["broadcast"] as? String, !broadcast.isEmpty { profile.broadcast = broadcast }
            if let port = wake["port"] as? Int, let port = UInt16(exactly: port) { profile.port = port }

            // The remote host is the owner's to set, on the PC or here. Taken from the PC when it
            // has one and this phone does not, so setting it once on either side is enough.
            if let host = wake["remoteHost"] as? String, !host.isEmpty, profile.remoteHost.isEmpty {
                profile.remoteHost = host
            }
            if let port = wake["remotePort"] as? Int, let port = UInt16(exactly: port), port > 0 {
                profile.remotePort = port
            }

            profile.save()
            wakeProfile = profile
            note("network: \(remote.count) remote, \(local.count) local, wake \(profile.mac == nil ? "unavailable" : profile.mac!.description)")
        }
    }

    /// Saves what the owner typed for waking the PC from outside, and keeps the rest as the PC said it.
    func setWakeRemote(host: String, port: UInt16?) {
        var profile = wakeProfile
        profile.remoteHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port, port > 0 { profile.remotePort = port }
        profile.save()
        wakeProfile = profile
    }

    func setWakeEnabled(_ on: Bool) {
        var profile = wakeProfile
        profile.enabled = on
        profile.save()
        wakeProfile = profile
    }

    func setWakeOverCellular(_ on: Bool) {
        var profile = wakeProfile
        profile.overCellular = on
        profile.save()
        wakeProfile = profile
    }

    func setPreferLocal(_ on: Bool) {
        guard var paired = pc else { return }
        paired.preferLocal = on
        paired.save()
        pc = paired
    }

    // MARK: connection

    /// How the phone is reaching the PC right now: at home, or through the away-from-home address.
    @Published private(set) var route: String?

    /// The last connection attempts, newest last - which route, how long, and how each ended. Shown in Settings so a
    /// connection that will not come up can be seen rather than guessed at.
    @Published private(set) var connectionLog: [String] = []

    private func note(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        connectionLog = Array((connectionLog + ["\(stamp) \(line)"]).suffix(12))
    }

    /// Runs `operation`, but gives up after `seconds`: `cancel` then closes the connection, which ends whatever the
    /// operation was waiting for. A connection that stalls on mobile data must not hold every later attempt forever.
    private static func within<T: Sendable>(_ seconds: Double, cancel: @escaping @Sendable () async -> Void,
                                            _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await cancel()
                return nil
            }
            while let result = try await group.next() {
                if let value = result {
                    group.cancelAll()
                    return value
                }
            }
            throw BridgeError.timedOut
        }
    }

    /// The connection attempt in flight, if any. Everything that needs the PC while one is running waits for it rather
    /// than starting its own: on mobile data several attempts at once used to replace each other, and each replaced one
    /// closing looked like the connection dropping.
    private var connecting: Task<Void, Never>?

    func connect() async {
        if let connecting {
            await connecting.value
            return
        }
        let attempt = Task { await self.connectNow() }
        connecting = attempt
        await attempt.value
        connecting = nil
    }

    /// Every way this phone could reach the PC, best first, each given a short turn.
    ///
    /// This was two candidates and a coin toss - the home address and a typed away-from-home one,
    /// ordered by whether the phone was on mobile data - which is wrong in both directions. On a
    /// café's Wi-Fi the phone is not on cellular, so the home address went first and reached
    /// nothing. On mobile data with nothing typed there was nothing to try at all.
    ///
    /// Now the PC hands over every address it has while the phone is at home, and
    /// `BridgeEndpointResolver` puts them in order for where the phone is now. Each gets
    /// `perCandidate` seconds rather than twelve: an address that cannot be reached from this
    /// network does not fail, it waits, so the timeout is the thing that moves on to the next one.
    private func connectNow() async {
        guard let pc else { link = .unpaired; return }
        if let client, await client.isOpen, link.isOnline { return }

        link = .connecting

        let candidates = BridgeEndpointResolver.candidates(
            for: pc,
            discovered: browser.found,
            cellular: network.cellular,
            preferLocal: pc.preferLocal ?? true)

        guard !candidates.isEmpty else {
            note("no address to try: \(network.cellular ? "on mobile data with no away-from-home address" : "nothing found on this network")")
            route = nil
            link = .offline("No way to reach the PC from here yet. Connect once at home, and it will tell this phone where else to find it.")
            scheduleReconnect()
            return
        }

        note("\(network.cellular ? "cellular" : "wi-fi"): \(candidates.count) to try")

        var lastError: Error = BridgeError.closed
        for candidate in candidates {
            if Task.isCancelled { return }

            // Mobile data gets longer and gets to sit through "not yet": the list is short there,
            // so there is nothing else to spend the time on, and "not yet" is how a connection over
            // a cellular radio and an on-demand tunnel begins rather than how it fails.
            // The live reading rather than the published mirror: this decides how to connect, and
            // it should use what the network is doing now rather than what the views were last told.
            let cellularNow = network.cellular
            let client = BridgeClient(
                endpoint: candidate.endpoint,
                connectWithin: BridgeEndpointResolver.patience(cellular: cellularNow),
                patientWhileWaiting: cellularNow)

            let identity = ObjectIdentifier(client)
            await client.setHandlers(
                push: { message in Task { @MainActor in AppModel.shared.handlePush(message) } },
                close: { error in Task { @MainActor in AppModel.shared.dropped(error, from: identity) } })

            let started = Date()
            note("trying \(candidate.describedAs)")
            do {
                let deviceId = pc.deviceId, serverKey = pc.serverKey
                let name = try await Self.within(BridgeEndpointResolver.patience(cellular: cellularNow) + 6, cancel: { await client.close() }) {
                    try await client.resume(deviceId: deviceId, pinnedServerKey: serverKey)
                }
                note(String(format: "%@: online in %.1f s", candidate.describedAs, Date().timeIntervalSince(started)))
                self.client = client
                failures = 0
                ControlModel.shared.connectionChanged()
                controlling = false
                self.route = candidate.describedAs
                link = .online(name)
                wakeState = nil
                await refresh()
                return
            } catch {
                await client.close()
                lastError = error
                note(String(format: "%@: %@ after %.1f s", candidate.describedAs, error.localizedDescription, Date().timeIntervalSince(started)))
                // A PC that no longer knows this phone will not know it by another route either -
                // the identity it refuses is the same identity on every address.
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

        // While the app is in front, keep telling the PC so - and stop the moment it is not, which
        // is what makes the silence mean something. The PC forgets after ninety seconds.
        if phase == .active {
            startSayingWeAreHere()
        } else {
            stopSayingWeAreHere()
        }

        if phase == .active {
            // Bonjour runs while the app is open: seeing the PC on this network is proof the phone
            // is at home, which beats any guess from the interface type.
            browser.start()
            Task { await connect() }
        } else if phase == .background && !wake.running {
            browser.stop()
            // Without background audio iOS suspends the app anyway; close cleanly so the PC's count is right.
            Task { await disconnect() }
        }
    }

    private var presenceHeartbeat: Task<Void, Never>?

    /// Says "still in hand" every so often, for as long as the app is in front.
    ///
    /// A repeat rather than one message, because the PC deliberately forgets a device that has gone
    /// quiet - that is what lets the phone stay honest by saying nothing when it stops knowing. The
    /// first report is the one `refresh` already sends on connecting; this keeps it from expiring
    /// under somebody who is still holding the phone.
    private func startSayingWeAreHere() {
        guard presenceHeartbeat == nil else { return }

        presenceHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.presenceEvery))

                if Task.isCancelled { return }

                await self?.reportPresence()
            }
        }
    }

    private func stopSayingWeAreHere() {
        presenceHeartbeat?.cancel()
        presenceHeartbeat = nil
    }

    /// A connection closed. Only the one in use counts: an attempt that lost a race, or one already replaced, closing
    /// is not the PC going away.
    private func dropped(_ error: Error?, from identity: ObjectIdentifier) {
        guard let client, ObjectIdentifier(client) == identity else { return }
        self.client = nil
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

    /// How often to say "still here" while the app is in front.
    ///
    /// The PC forgets a device that has been silent for ninety seconds, which is the whole reason
    /// this can be honest: the phone says what it knows while it knows it, and says nothing rather
    /// than claiming the opposite when it stops knowing.
    nonisolated static let presenceEvery: TimeInterval = 45

    /// Tells the PC what this phone can honestly say about itself.
    ///
    /// The PC asks every device it can reach, and uses the answers to decide which of them should
    /// speak. It has been asking since the bridge was written and this phone has never once
    /// answered - so an input into that decision has been missing, from a device that has it.
    ///
    /// **"Worn" is not "in my hand".** It means what the arbiter weighs it as: on the user and
    /// heard by nobody else. A phone's speaker is as public as the PC's, so a phone being held is
    /// not that at all - reporting it would send private answers to a loudspeaker on a table. What
    /// is the same thing for a phone is where its audio is going: headphones or an earpiece are
    /// heard by the owner and nobody else, and the phone knows which.
    ///
    /// **Busy** is audio somebody else started - a call, a video, another app's music - because
    /// that is the case where an answer spoken here would talk over something.
    ///
    /// Nothing is claimed while the app is in the background: what a phone can see of its own
    /// audio route is only true while it is in front, and the PC forgets a device that has gone
    /// quiet after ninety seconds. Silence is the honest answer, not a guess.
    func reportPresence() async {
        guard link.isOnline, let client = try? await session() else { return }

        let audio = AVAudioSession.sharedInstance()

        _ = try? await client.request("presence", [
            "worn": Self.privateAudio(audio.currentRoute.outputs.map(\.portType)) ? 1 : 0,
            "busy": audio.isOtherAudioPlaying ? 1 : 0
        ])
    }

    /// Whether what this phone plays would be heard by its owner alone.
    ///
    /// Headphones and the earpiece, wired or not. Deliberately not AirPlay or a car: those are
    /// somewhere else in the room or the vehicle, which is the opposite of private, and the built-in
    /// speaker least of all.
    /// Takes the port types rather than the route, so this can be checked without an audio session -
    /// a route description is not something a test can build.
    nonisolated static func privateAudio(_ outputs: [AVAudioSession.Port]) -> Bool {
        let heardOnlyByTheOwner: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .builtInReceiver, .usbAudio
        ]

        return outputs.contains { heardOnlyByTheOwner.contains($0) }
    }

    func refresh() async {
        guard let client = try? await session() else { return }
        if let reply = try? await client.request("status") { status = reply.body }
        if let reply = try? await client.request("security.status") { security = SecuritySnapshot(reply.body) }

        // Where else this PC can be reached, and how it would be woken, straight from the PC. An
        // older PC that does not know the request answers "failed" and this quietly does nothing,
        // which is exactly what should happen: the app keeps whatever it already had.
        if let reply = try? await client.request("network"), reply.kind == "network" { learnNetwork(reply.body) }

        // Anything the phone recorded while the PC was off. Sent oldest first, and it stops at the
        // first one that will not go rather than skipping it, so the PC's trail stays in order.
        await whereabouts.flush()

        // And that this phone is in somebody's hand, which the PC cannot see for itself.
        await reportPresence()
    }

    // MARK: asking

    func ask(_ text: String, spoken: Bool = false) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        lines.append(ChatLine(speaker: .you, text: request))

        // The few requests this phone must answer itself, because the PC cannot: "wake my PC" sent
        // to a sleeping PC is a request with nowhere to go. One reading of the sentence, used by the
        // typed box, the wake word and Siri alike - so the button and the words are the same action.
        if case .wake = LocalCapability.of(request), !link.isOnline {
            lines.append(ChatLine(speaker: .jarvis, text: wakeAnswer()))
            wakePC()
            return
        }

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
        // The best way to reach the PC is a different one on a different network, so the whole
        // question is asked again rather than the current answer being kept. Wi-Fi to cellular,
        // cellular to Wi-Fi, a VPN coming up or going away: each of them changes which candidate
        // wins, and an app that only notices at the next reconnect is an app that sits offline in
        // the owner's pocket until they open it.
        onCellular = network.cellular
        note("network changed: \(onCellular ? "cellular" : "wi-fi")")

        Task {
            if !link.isOnline {
                await connect()
            } else if let client, !(await client.isOpen) {
                // The interface changed under an open connection. A socket on an interface that has
                // gone does not always report itself closed; asking is cheap and being wrong here
                // is an app that looks connected and answers nothing.
                await disconnect()
                await connect()
            }
        }

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
        if message.kind == "devices.changed" { SmartHomeModel.shared.receive(message); return }
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
        wakeState = nil
        wakeProfile = .default
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

    // MARK: alerts while the app is closed

    /// The private ntfy topic the PC sends alerts to while this app is closed; nil when off.
    @Published private(set) var alertsTopic: String? = UserDefaults.standard.string(forKey: "ntfyTopic")

    /// Turns alerts-while-closed on with a fresh random topic (or off), on the PC and here.
    func setAlerts(_ on: Bool) async {
        let topic = on ? Self.newTopic() : ""
        do {
            let reply = try await session().request("alerts.set", ["topic": topic])
            guard reply.kind == "done" else { toast = reply.message; return }
            alertsTopic = on ? topic : nil
            UserDefaults.standard.set(alertsTopic, forKey: "ntfyTopic")
            toast = reply.message
        } catch {
            toast = error.localizedDescription
        }
    }

    /// 128 bits of randomness in letters and digits: nobody can guess it, so nobody else can read or send to it.
    private static func newTopic() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return "jarvis-" + String((0..<26).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
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

#if DEBUG
// MARK: screenshots

extension AppModel {
    /// Puts the model in a believable state for the screenshot tests: a paired PC that is answering,
    /// and a short conversation. Debug builds only, and called from nowhere but the tests - a release
    /// build does not contain it, so it cannot put pretend state in front of anybody.
    func showcase(pcName: String, lines script: [(ChatLine.Speaker, String)]) {
        link = .online(pcName)
        lines = script.map { ChatLine(speaker: $0.0, text: $0.1) }
    }
}
#endif
