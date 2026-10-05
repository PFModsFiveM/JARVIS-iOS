import AVFoundation
import Foundation
import Network
import SwiftUI
import UserNotifications
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
    /// The Settings page a `jarvis://settings/<slug>` link asked for. Set by the URL handler, read
    /// and cleared by `SettingsView`, so a link that arrives while another tab is open still lands
    /// on the right page once Settings comes forward.
    @Published var settingsRoute: SettingsDestination?
    @Published private(set) var awaitingVoice = false

    /// Live view: the PC's displays, the one being watched, and its latest frame.
    struct ScreenDisplayInfo: Identifiable, Equatable {
        let index: Int
        let name: String
        let width: Int
        let height: Int
        let primary: Bool
        var id: Int { index }

        /// What fits on a segmented control: "Main", "Left", "Right", and a star for the primary.
        var shortName: String {
            let first = name.split(separator: " ").first.map(String.init) ?? "\(index + 1)"
            return primary ? "\(first) \u{2605}" : first
        }
    }
    @Published private(set) var screenDisplays: [ScreenDisplayInfo] = []
    @Published private(set) var liveDisplay: Int?
    @Published private(set) var screenFrame: UIImage?
    @Published private(set) var screenFramesPerSecond = 0.0

    /// The room, live. Nil when nothing is being watched.
    @Published private(set) var cameraFrame: UIImage?
    @Published private(set) var watchingCamera = false
    private var newestCameraFrame = -1
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
        /// The PC's pre-login service answered after a wake, so the machine is on and the wake worked,
        /// but desktop JARVIS has not answered. Carries the sentence saying why, from the service.
        case awakeWithoutJarvis(String)
        case connectionFailed(String)
        case unpaired

        var headline: String {
            switch self {
            case .offline, .wakeAvailable: return "OFFLINE"
            case .wakeRequested, .waking: return "WAKING..."
            case .bridgeConnecting: return "CONNECTING"
            case .online: return "ONLINE"
            case .wakeTimedOut: return "NO ANSWER"
            case .awakeWithoutJarvis: return "ON"
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
            case .awakeWithoutJarvis(let why): return why
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

    #if DEBUG
    /// Set by the screenshot tests' showcase only: the model keeps the state it was given and does not
    /// dial out, so a screen drawn in CI shows the connected look rather than a reconnect in progress.
    var showcasing = false
    #endif

    /// What this phone knows about waking the PC. Told to it by the PC; never typed unless the owner insists.
    @Published var wakeProfile = WakeProfile.load()

    /// How long to wait for the PC to answer after a wake request.
    ///
    /// Ninety seconds. A machine coming out of sleep is on the network in five to fifteen; one
    /// coming from hibernate or a cold start takes longer, and Tailscale needs a moment after that
    /// to reconnect. Long enough not to give up on a working wake, short enough that a wake that
    /// did nothing does not leave the page saying "waiting" for ever.
    static let wakeWindow = 90

    /// Looks the remote name up before sending, so a wake that does nothing can say what it resolved to.
    private let wakeService = WakeOnLanService(resolve: WakeOnLanService.ipv4)

    /// The last wake attempt, as evidence: route, name, what it resolved to, port, packets, when.
    @Published private(set) var lastWake: WakeOutcome?
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
        lastWake = outcome

        guard outcome.sent else {
            note("wake: \(outcome.because)")
            wakeState = .connectionFailed(outcome.because)
            return
        }

        note("wake: sent \(outcome.packets) packets \(outcome.strategy == .localBroadcast ? "to the home broadcast" : "through the router")\(outcome.resolved.map { " (resolved \($0))" } ?? "")")
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

            // A failed connection has already asked the pre-login service why (machineSaysWhy). If
            // it answered since this wake began, the machine is on: a PC woken from off comes up with
            // nobody signed in, and desktop JARVIS would never answer however long this waited.
            if let report = MachineLink.shared.report, report.at >= started {
                machineIsOn(report)
                return
            }

            try? await Task.sleep(for: .seconds(3))
            wakeState = .waking(sent: outcome.destination, seconds: Int(Date().timeIntervalSince(started)))
        }

        if MachineLink.shared.isPaired, let report = await MachineLink.shared.ask(force: true) {
            machineIsOn(report)
            return
        }

        note("wake: no answer after \(Self.wakeWindow) s; delivery of the packets is unconfirmed")
        wakeState = .wakeTimedOut(outcome.destination)
    }

    /// The pre-login service answered after a wake: the machine is on and the wake worked. Said as
    /// the service describes the session, because "JARVIS isn't running" is only sometimes the reason.
    private func machineIsOn(_ report: MachineReport) {
        note("wake: the PC's service answered (\(report.summary)); the machine is on")

        let why: String
        switch report.session {
        case .nobodySignedIn: why = "nobody has signed in yet, so desktop JARVIS isn't running."
        case .locked: why = report.desktopRunning ? "it's locked; JARVIS is running and will answer once it is unlocked." : "it's locked and desktop JARVIS isn't running."
        case .inUse: why = report.desktopRunning ? "JARVIS is running, but this phone couldn't reach it yet." : "desktop JARVIS isn't running."
        case .unknown: why = "it couldn't say what it is doing."
        }

        wakeState = .awakeWithoutJarvis("\(report.machine) is on - the wake worked - but \(why)")
    }

    // MARK: diagnosing a wake before it is needed

    /// What the PC says about whether it can be woken. Asked while it is awake.
    @Published private(set) var wakeReadiness: WakeReadinessReport?

    /// The last answer from the PC's wake-path listener.
    @Published private(set) var wakeProbe: WakeProbeReport?

    /// Why the last diagnosis request did not produce an answer, when it did not.
    @Published private(set) var wakeDiagnosisProblem: String?

    /// Asks the PC to read its own wake setup. Needs the PC awake and connected.
    func checkWakeReadiness() async {
        do {
            let reply = try await session().request("wake.readiness", timeout: 30)
            guard reply.kind == "wake.readiness", let report = WakeReadinessReport.read(reply.body) else {
                wakeDiagnosisProblem = reply.message
                return
            }
            wakeReadiness = report
            wakeDiagnosisProblem = nil
            note("wake check: \(report.firstProblem.map { "first problem: \($0.title)" } ?? "no problem found")")
        } catch {
            wakeDiagnosisProblem = error.localizedDescription
        }
    }

    /// Asks the PC to listen for wake packets for a few minutes, so a wake sent now can be seen arriving.
    func startWakeProbe() async { await wakeProbeRequest("wake.probe.start", ["seconds": 180]) }

    /// What the PC's listener has heard so far.
    func readWakeProbe() async { await wakeProbeRequest("wake.probe") }

    private func wakeProbeRequest(_ kind: String, _ body: [String: Any] = [:]) async {
        do {
            let reply = try await session().request(kind, body, timeout: 15)
            guard reply.kind == "wake.probe", let report = WakeProbeReport.read(reply.body) else {
                wakeDiagnosisProblem = reply.message
                return
            }
            wakeProbe = report
            wakeDiagnosisProblem = nil
        } catch {
            wakeDiagnosisProblem = error.localizedDescription
        }
    }

    /// Sends one wake burst the way this phone would from where it is, without waiting for the PC -
    /// it is already awake. The listener on the PC is what reports whether it arrived.
    func sendTestWake() async {
        let outcome = await wakeService.wake(wakeProfile, cellular: network.cellular)
        lastWake = outcome
        note(outcome.sent
             ? "wake test: sent \(outcome.packets) packets \(outcome.strategy == .localBroadcast ? "to the home broadcast" : "through the router")"
             : "wake test: \(outcome.because)")
    }

    /// What JARVIS says when asked to wake the PC. Never that it is awake - only that it was asked.
    func wakeAnswer() -> String {
        let name = wakeProfile.deviceName.isEmpty ? "your PC" : wakeProfile.deviceName

        if !wakeProfile.enabled { return MobilePhrases.wakingIsOff(name) }
        if wakeProfile.mac == nil {
            return MobilePhrases.cardUnknown(name)
        }
        if WakeOnLanService.strategies(for: wakeProfile, cellular: network.cellular).isEmpty {
            return MobilePhrases.onlyFromHome(name)
        }

        return MobilePhrases.sendingWake(name)
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
            // What the owner typed wins. The PC is usually right and is right more often than a
            // person typing hex - but somebody who typed it did so because this was not working,
            // and quietly replacing it would take the fix away while looking like nothing happened.
            if let mac = MacAddress(wake["mac"] as? String), profile.typedByHand != true || profile.mac == nil {
                profile.mac = mac
            }
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

    /// Takes a card address and a broadcast address typed by hand.
    ///
    /// Everything else about waking is learnt: the PC reads its own card and tells the phone over
    /// the bridge, so there is nothing to type and nothing to get wrong. That is the right default
    /// and it has one hole in it - the phone has to have connected to the PC at least once, which
    /// it cannot do if the PC has been off ever since the app was installed. The wake button is
    /// then unavailable for exactly the machine somebody wants to switch on.
    ///
    /// So the two facts can be typed. They are on the PC's own `SpeechDiag network` screen, and on
    /// any router's page. What is typed is kept: a later connection fills in what is still empty
    /// rather than overwriting an address somebody went to the trouble of entering.
    ///
    /// Returns what was wrong, or nil when it took.
    func setWakeCard(mac: String, broadcast: String) -> String? {
        let typed = mac.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let card = MacAddress(typed) else {
            return MobilePhrases.notACardAddress()
        }

        let where_ = broadcast.trimmingCharacters(in: .whitespacesAndNewlines)

        // A broadcast address ends in 255 on every home network there is. Not enforced - somebody
        // with an unusual mask knows more about their network than this does - but worth saying.
        var profile = wakeProfile
        profile.mac = card
        if !where_.isEmpty { profile.broadcast = where_ }
        profile.typedByHand = true
        profile.save()
        wakeProfile = profile

        note("wake: card typed by hand")

        return nil
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
        #if DEBUG
        if showcasing { return }
        #endif
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
        link = .offline(await machineSaysWhy(lastError))
        scheduleReconnect()
    }

    /// Why the desktop did not answer, asked of the machine itself when it can be.
    ///
    /// "The PC did not answer in time" is true and nearly useless: it is the same sentence whether
    /// the machine is asleep, or on with nobody signed in, or on and locked with JARVIS not
    /// running. The pre-login service knows which, and answering that is most of the reason it
    /// exists - so when the desktop cannot be reached, it is asked, and what it says is what the
    /// owner is told.
    private func machineSaysWhy(_ failure: Error) async -> String {
        guard MachineLink.shared.isPaired, let report = await MachineLink.shared.ask(force: true) else {
            return failure.localizedDescription
        }

        switch report.session {
        case .nobodySignedIn:
            return "\(report.machine) is on, but nobody has signed in yet, so JARVIS is not running."
        case .locked:
            return report.desktopRunning
                ? "\(report.machine) is locked. JARVIS is running and will answer once it is unlocked."
                : "\(report.machine) is locked and JARVIS is not running."
        case .inUse:
            return report.desktopRunning
                ? "\(report.machine) is awake and JARVIS is running, but this phone could not reach it: \(failure.localizedDescription)"
                : "\(report.machine) is awake, but JARVIS is not running on it."
        case .unknown:
            return "\(report.machine) is on, but could not say what it is doing."
        }
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

        // This phone as a node of the one timeline - programme §9 and §10.
        //
        // On every connection rather than on a button. The owner granted the pairing; being asked
        // to press Sync afterwards would mean JARVIS knew less than it could because nobody
        // tapped. Push first, then pull: what this phone observed while the PC was off is the
        // thing most likely to be missing, and the pull is how it finds out what happened at the
        // desk while it was away.
        timeline.identify(as: pc?.deviceId ?? "")
        await timeline.sync(exchanging)

        // And the places the owner goes, so this phone can name where it is with the desk off -
        // programme §1C. On every connection, incrementally, and with no button anywhere.
        await pullPlaces()

        // What the owner's words mean, so this phone can resolve "the bedroom lamp" with the desk
        // asleep - priority §4D. In the path of every command, which is why it is pulled rather
        // than asked for.
        await pullAliases()

        // And what has already been said, so this phone does not say it again - priority §1D.
        // Reported first: something this phone said while the PC was unreachable is the one fact
        // the PC cannot have.
        await settleDelivery()

        // A few more of JARVIS's own phrases, so the voice survives the desk going to sleep.
        await warmTheVoiceCache()

        // What this phone may work by itself while the PC is off.
        //
        // Here, on every connection, rather than when a screen that shows devices happens to open -
        // which is where it used to be, and the reason standalone control was unreliable rather
        // than broken. An owner who paired, used the voice path and never opened the smart-home
        // screen had an empty binding table, so with the PC off there was nothing to match a light
        // against and JARVIS said the PC was not answering. The bindings are what makes the phone
        // independent; they cannot be learned as a side effect of navigation.
        await SmartHomeModel.shared.learnStandby(client)

        // Anything the phone recorded while the PC was off. Sent oldest first, and it stops at the
        // first one that will not go rather than skipping it, so the PC's trail stays in order.
        await whereabouts.flush()

        // And that this phone is in somebody's hand, which the PC cannot see for itself.
        await reportPresence()

        // And its battery, which the PC cannot read for itself either. Everything rather than only
        // what changed: this may be the first the PC has heard, and a reading it never received is
        // indistinguishable from one that has not moved.
        await PowerReporter.shared.reportEverything()

        // And whether any of that is worth telling the owner about while they are not looking -
        // programme §57. Every decision is `JarvisNotices`'; this is the one line that says when
        // to consider it, which is on every connection and every state change.
        await NoticeCentre.shared.consider(
            nodeState,
            power: PowerReporter.shared.readings,
            queued: timeline.state.queued)

        // And what every other node said. The headset's battery is readable only by the PC it is
        // paired to, so this is the only way it reaches a phone at all.
        await PowerReporter.shared.askTheOthers { kind in
            guard let client = try? await self.session() else { throw BridgeError.closed }
            return try await client.request(kind)
        }
    }

    /// The shared timeline, as this phone's node of it.
    var timeline: OwnerTimelineClient { OwnerTimelineClient.shared }

    /// Puts one request on the bridge and hands back its body.
    ///
    /// The seam the timeline client is built against, so it can be tested without an app, a PC or
    /// a network - and so the one place that knows how to reach the PC stays here.
    /// Catches this phone's place and routine subset up with the PC - programme §1C and §2B.
    ///
    /// Incremental by revision, so an ordinary connection costs one request that returns nothing.
    /// Places first and routines second, because a routine is about a place: pulling them the
    /// other way round would briefly hold a pattern about somewhere this phone could not name.
    ///
    /// Routines are asked for only when the places moved, since the PC stamps both with the same
    /// revision - an unchanged place book means an unchanged routine model, and asking anyway
    /// would be a request per connection that always returns the same two dozen rows.
    func pullPlaces() async {
        let book = MobilePlaceBook.shared

        // Names the owner gave go first. They are the one thing here the PC does not already know
        // and cannot work out, and a pull that overwrote the local row before the name was sent
        // would quietly discard what the owner said.
        for (id, name) in book.unsent {
            do {
                _ = try await exchanging("places.name", ["id": id, "name": name])
                book.sent(id)
            } catch {
                // Kept, and tried again on the next connection.
                book.failed(MobilePlaceBook.because(error))
            }
        }

        do {
            var more = true
            var moved = false

            // Looped, because a phone that has been away for a long time gets its places in
            // batches; bounded by the PC's own batch size so a loop cannot run away.
            var rounds = 0

            while more, rounds < 8 {
                rounds += 1

                let reply = try await exchanging("places.pull", ["since": book.revision])
                let rows = (reply["rows"] as? [[String: Any]] ?? []).map { row in
                    row.reduce(into: [String: String]()) { into, pair in
                        into[pair.key] = pair.value as? String ?? String(describing: pair.value)
                    }
                }

                let through = (reply["through"] as? NSNumber)?.int64Value
                let changed = book.apply(rows, through: through)

                moved = moved || changed > 0
                more = (reply["more"] as? Bool) ?? false

                if rows.isEmpty { break }
            }

            guard moved || MobileRoutineBook.shared.revision < book.revision else { return }

            let patterns = try await exchanging("routines.pull", ["since": MobileRoutineBook.shared.revision])
            let rows = (patterns["rows"] as? [[String: Any]] ?? []).map { row in
                row.reduce(into: [String: String]()) { into, pair in
                    into[pair.key] = pair.value as? String ?? String(describing: pair.value)
                }
            }

            if !rows.isEmpty {
                MobileRoutineBook.shared.replace(
                    rows, revision: (patterns["revision"] as? NSNumber)?.int64Value ?? book.revision)
            }
        } catch {
            // The cursor has not moved, so the next connection asks for the same thing again. A
            // failed place pull must not be allowed to fail the whole refresh: the smart-home
            // bindings and the timeline matter more and are pulled around it.
            book.failed(MobilePlaceBook.because(error))
        }
    }

    /// What the owner's words mean, pulled incrementally - priority §4D and §6A.
    ///
    /// Separate from the place pull despite looking the same, because the two fail independently:
    /// a phone whose vocabulary is stale can still say where it is, and a phone with stale places
    /// can still switch a light the owner named. Folding them together would mean one failure took
    /// both.
    func pullAliases() async {
        let book = MobileAliases.shared

        do {
            let reply = try await exchanging("aliases.pull", ["since": book.revision])

            let rows = (reply["aliases"] as? [[String: Any]] ?? []).compactMap(Self.alias)
            let gone = (reply["forgotten"] as? [[String: Any]] ?? [])
                .compactMap { $0["said"] as? String }

            book.apply(
                rows,
                forgotten: gone,
                through: (reply["revision"] as? NSNumber)?.int64Value ?? book.revision)
        } catch {
            // The cursor has not moved, so the next connection asks again. An older PC that does
            // not know the request answers "failed", and this quietly keeps what it already had -
            // which is the right behaviour, not a silent failure: the words the phone knows are
            // still the words the owner used.
            book.couldNotCatchUp(MobilePlaceBook.because(error))
        }
    }

    /// One row of `aliases.pull`, refusing anything that is not a whole alias.
    ///
    /// Tolerant of fields it does not know and strict about the four it needs, so a newer PC can
    /// add to the reply without this build dropping every row.
    private static func alias(_ row: [String: Any]) -> MobileAlias? {
        guard let said = row["said"] as? String, !said.isEmpty,
              let entity = row["entity"] as? String, !entity.isEmpty else { return nil }

        return MobileAlias(
            said: MobileAliases.normalise(said),
            entity: entity,
            kind: MobileEntityKind(rawValue: row["kind"] as? String ?? "") ?? .unknown,
            strength: MobileEvidence(rawValue: row["strength"] as? String ?? "") ?? .weak,
            trusted: (row["trusted"] as? Bool) ?? false,
            confidence: (row["confidence"] as? NSNumber)?.doubleValue ?? 0,
            count: (row["count"] as? NSNumber)?.intValue ?? 1,
            revision: (row["revision"] as? NSNumber)?.int64Value ?? 0)
    }

    /// Reports what this phone said while the PC was away, then learns what it missed - §1D.
    ///
    /// The order is the whole of it. This phone's own record of what it said is the only copy
    /// while the PC is unreachable; pulling first and reporting second would mean a result the
    /// phone had already spoken came back as Ready and could be spoken again.
    func settleDelivery() async {
        let book = MobileDelivery.shared
        let me = pc?.deviceId ?? ""

        for resultId in book.unreported() {
            do {
                let reply = try await exchanging("delivery.done", ["result": resultId, "way": "Spoken"])

                if (reply["accepted"] as? Bool) == true {
                    book.reported(resultId, by: me)
                }
            } catch {
                // Kept. It is reported on the next connection, and until then this phone's own
                // record is what stops it repeating itself.
                book.couldNotCatchUp(MobilePlaceBook.because(error))
            }
        }

        do {
            let reply = try await exchanging("delivery.pull", ["since": book.revision])

            let rows = (reply["results"] as? [[String: Any]] ?? []).compactMap(Self.result)

            book.apply(rows, through: (reply["revision"] as? NSNumber)?.int64Value ?? book.revision)
        } catch {
            book.couldNotCatchUp(MobilePlaceBook.because(error))
        }
    }

    /// One row of `delivery.pull`. Deliberately has no field for the words.
    ///
    /// The PC does not send them and this would have nowhere to put them if it did. A phone
    /// catching up is learning what not to say, and the only use it would have for the sentence is
    /// to say it.
    private static func result(_ row: [String: Any]) -> MobileResult? {
        guard let id = row["result"] as? String, !id.isEmpty else { return nil }

        return MobileResult(
            id: id,
            turn: row["turn"] as? String ?? "",
            conversation: row["conversation"] as? String ?? "",
            task: row["task"] as? String,
            state: MobileDeliveryState(rawValue: row["state"] as? String ?? "") ?? .ready,
            by: row["by"] as? String,
            revision: (row["revision"] as? NSNumber)?.int64Value ?? 0,
            because: row["because"] as? String ?? "")
    }

    var exchanging: (String, [String: Any]) async throws -> [String: Any] {
        { [weak self] kind, body in
            guard let self else { throw BridgeError.closed }
            return try await self.session().request(kind, body, timeout: 25).body
        }
    }

    /// Files one observation this phone made, and lets the client decide when it travels.
    ///
    /// Takes the exchange rather than reaching for it, so an observation made with the PC off is
    /// queued by exactly the same call that sends one made with the PC up.
    func observe(
        _ type: String,
        _ category: OwnerEventCategory,
        payload: [String: String] = [:],
        occurred: Date = Date(),
        confidence: Double = 1,
        sensitivity: OwnerEventSensitivity = .medium,
        key: String
    ) {
        timeline.record(
            type,
            category: category,
            payload: payload,
            occurred: occurred,
            confidence: confidence,
            sensitivity: sensitivity,
            key: key,
            exchange: link.isOnline ? exchanging : nil)
    }

    /// Starts reporting this phone's power, once.
    ///
    /// Here rather than in the reporter because the reporter does not own the connection and should
    /// not: it reads batteries and words them, and this is the one line that says where the rows go.
    func startReportingPower() {
        PowerReporter.shared.send = { [weak self] readings in
            guard let self, let client = try? await self.session() else { return }
            _ = try? await client.request("power.report", ["devices": readings.map(\.row)])
        }

        PowerReporter.shared.start()
    }

    // MARK: asking

    /// Whether the PC has said this phone may read the current answer out.
    ///
    /// Defaults to true so that a phone with no PC to ask - away from home, or the bridge down -
    /// behaves exactly as it always did rather than going mute.
    @Published private(set) var mayReadAloud = true

    /// Asks the PC whether to take this turn out loud.
    ///
    /// Only for turns the phone started by hearing something. A typed question is unambiguous: the
    /// person is looking at the phone and typed into it, so nothing needs arbitrating.
    private func claimTurn(spoken: Bool) async {
        guard spoken, link.isOnline else { mayReadAloud = true; return }

        do {
            let reply = try await session().request("conversation.claim", [
                "turnId": UUID().uuidString,
                "listening": 1,
                "foreground": UIApplication.shared.applicationState == .active ? 1 : 0
            ], timeout: 4)

            mayReadAloud = reply.body["granted"] as? Bool ?? true
        } catch {
            // The PC could not be asked. Answering is better than silence, and a duplicate is the
            // lesser fault when the alternative is a phone that has stopped working.
            mayReadAloud = true
        }
    }

    func ask(_ text: String, spoken: Bool = false) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        await claimTurn(spoken: spoken)

        lines.append(ChatLine(speaker: .you, text: request))

        // Which node this belongs to. One decision, in `MobileCapabilities.decide`, used by the
        // typed box, the wake word and Siri alike - so the button and the words are the same
        // action. A PC that is answering gets everything, including the requests this phone could
        // handle itself: it understands the sentence better than any reading here and owns the
        // device state. What this phone could have done becomes the fallback rather than being
        // discarded, which is what makes a PC dropping mid-request survivable.
        let decision = MobileCapabilities.decide(request, devices: SmartHomeModel.shared.standby, state: nodeState)

        if await follow(decision.lane, request: request, spoken: spoken) { return }

        // The chosen lane did not work. This is almost always the PC: chosen because the bridge was
        // up a moment ago, gone by the time the request left. Before this, that came back to the
        // owner as a transport error for a light the phone could have switched itself.
        //
        // But a failed PC request is not always a request that did not happen - programme §7B. If
        // the PC received "switch the lamp" and only the reply was lost, sending the same thing
        // down the direct route presses the rocker a second time and the owner gets the light back
        // where it started. On and off survive being repeated; a toggle and a press do not.
        if let fallback = decision.fallback {
            if MobileCapabilities.mayFallBack(to: fallback, after: lastDelivery) {
                if await follow(fallback, request: request, spoken: spoken) { return }
            } else {
                let name = fallback.capability?.target
                    .flatMap { id in SmartHomeModel.shared.standby.first { $0.id == id }?.name }
                    ?? "it"

                let said = MobileCapabilities.mayHaveHappened(name)
                answer(said, spoken: spoken)
                fileTurn(request, said)
                return
            }
        }

        // Every lane failed, and the last one had the words for it.
        let said = MobileCapabilities.waiting(nodeState)
        lines.append(ChatLine(speaker: .jarvis, text: said))
        if speakAnswers || spoken { voice.say(said) }
    }

    /// Carries one lane out. Returns false when that lane could not do it, so a fallback may try.
    ///
    /// False means *this node could not*, never *the request failed*: a light that SwitchBot refused
    /// has been answered, honestly, and returns true. Only an unreachable node returns false, which
    /// is the one case where trying somewhere else is the right thing rather than a second attempt
    /// at the same thing.
    private func follow(_ lane: MobileCapabilities.MobileLane, request: String, spoken: Bool) async -> Bool {
        switch lane {
        case .unavailable(let because):
            answer(because, spoken: spoken)
            fileTurn(request, because)
            return true

        case .localMobile(let capability), .directDevice(let capability):
            return await carryOut(capability, request: request, spoken: spoken)

        // The cloud lane - programme §3 and §12. A general question with the PC off still has an
        // answer, and the answer is still JARVIS's: the provider is an executor, not a second
        // assistant, so the turn is filed into the same conversation with the provider named as
        // what carried it out.
        case .cloud:
            thinking = true

            let context = CloudContext.lines(for: request, from: CloudContext.Known(
                turns: recentTurns,
                place: PlaceResolution.read(
                    whereabouts.fix, in: MobilePlaceBook.shared.places).place?.spoken,
                pcAnswering: link.isOnline,
                pcName: pcName,
                routine: MobileRoutineBook.shared.routines.first.map(PlaceAnswers.describe)))

            // Held so the owner can stop it - priority §8B. A cloud question is the one thing this
            // phone does that can take twenty-five seconds with nothing to show, and a spinner
            // with no way out is how an app earns being force-quit.
            let question = Task { await CloudIntelligence.shared.ask(request, context: context) }
            cloudQuestion = question

            let said = await question.value
            cloudQuestion = nil
            thinking = false

            // Cancelled: the owner has already seen it stop, and answering with an empty line
            // would put a blank turn into a conversation the PC also reads.
            if said.isEmpty, question.isCancelled { return true }

            answer(said, spoken: spoken)
            fileTurn(request, said, executor: CloudIntelligence.shared.credential?.kind.rawValue)
            return true

        case .pcPrime:
            return await askThePC(request, spoken: spoken)
        }
    }

    /// One of the few requests this phone answers itself.
    private func carryOut(_ capability: LocalCapability, request: String, spoken: Bool) async -> Bool {
        switch capability {
        case .wake:
            let said = wakeAnswer()
            lines.append(ChatLine(speaker: .jarvis, text: said))
            wakePC()

            // A wake is a fact about a node rather than a turn of conversation, and the PC will
            // want it: it explains why it came up, which nothing at the desk can see for itself.
            observe(OwnerEventTypes.pcWoken, .node,
                    payload: ["node": pcName, "by": "phone"],
                    sensitivity: .low,
                    key: "\(pcName)|\(Int(Date().timeIntervalSince1970))")

            fileTurn(request, said)
            return true

        // The other thing a sleeping PC cannot be asked: what it is doing. The pre-login service
        // can answer it when JARVIS cannot, and when JARVIS can, it goes to JARVIS - which knows
        // everything the service does and a great deal more.
        case .state:
            let said = await machineAnswer()
            answer(said, spoken: spoken)
            fileTurn(request, said)
            return true

        // How a device is doing for battery. Readable only by the device it is in, so this phone
        // answers it from what it read itself - and the answer carries its age by the same rule the
        // PC uses, because a percentage in the present tense is a claim about now.
        case .power(let target):
            PowerReporter.shared.read()
            let matched = PowerReporter.matching(target, in: PowerReporter.shared.readings)

            let said = matched.isEmpty && target != nil
                ? MobilePhrases.nothingCalledWithABattery(target!)
                : PowerReporter.sayAll(matched)

            answer(said, spoken: spoken)
            fileTurn(request, said)
            return true

        // A light the PC cannot relay a command to, because it is off. The same action the panel's
        // switch takes, with the same routing and the same wording - and the answer is whatever
        // actually happened, including "sent, and I can't confirm it from here".
        case .device(let id, let command):
            thinking = true
            let said = await SmartHomeModel.shared.work(id, command)
            thinking = false
            answer(said, spoken: spoken)
            fileDeviceWork(id, command, said)
            fileTurn(request, said)
            return true

        case .deviceToggle(let id):
            thinking = true
            let said = await SmartHomeModel.shared.toggle(id)
            thinking = false
            answer(said, spoken: spoken)
            fileTurn(request, said)
            return true

        // How the whole of JARVIS is doing - programme §58. The PC answers it better when it is
        // up, because it can see every node's readings; with the PC off this phone is the only
        // node that can say which nodes are answering, so it says what it knows.
        case .status:
            PowerReporter.shared.read()

            let said = MobileStatus.line(
                nodeState,
                power: PowerReporter.shared.readings,
                queued: timeline.state.queued,
                behind: timeline.state.pcRevision - timeline.state.cursor)

            answer(said, spoken: spoken)
            fileTurn(request, said)
            return true

        // Where the owner is, or was - programme §1E. Answered from this phone's own fix, its own
        // record of the day and the places and patterns the PC published to it, so it works with
        // the desk switched off and needs no model and no network.
        case .whereabouts(let asked, let named):
            let said = PlaceAnswers.answer(asked, named: named, from: PlaceAnswers.Evidence(
                fix: whereabouts.fix,
                places: MobilePlaceBook.shared.places,
                visits: MobileDay.shared.visits,
                routines: MobileRoutineBook.shared.routines))

            answer(said, spoken: spoken)
            fileTurn(request, said)
            return true

        // The owner naming where they are - programme §31. Their word is authoritative, so it
        // takes effect here at once; the PC is told on the next connection rather than the owner
        // being told to wait for one.
        case .namePlace(let name):
            let verdict = PlaceResolution.read(whereabouts.fix, in: MobilePlaceBook.shared.places)

            guard let place = verdict.place else {
                let said = PlaceAnswers.cannotName(verdict)
                answer(said, spoken: spoken)
                fileTurn(request, said)
                return true
            }

            MobilePlaceBook.shared.rename(place.id, to: name)

            let said = PlaceAnswers.named(name, waiting: !link.isOnline)
            answer(said, spoken: spoken)
            fileTurn(request, said)

            // Best effort, now, so an owner at the desk sees it land immediately. If it fails the
            // name is still held and still unsent, and the next connection carries it.
            Task { await self.pullPlaces() }

            return true
        }
    }

    /// Files a device this phone worked without the PC - programme §7 and §26.
    ///
    /// The PC owns the device state and normally files this itself, but it cannot have seen a
    /// command it never relayed. Confirmation is carried honestly: a vendor accepting a command is
    /// not a rocker moving, and the confidence says so rather than the sentence having to.
    private func fileDeviceWork(_ id: String, _ command: StandbyCommand, _ said: String) {
        let name = SmartHomeModel.shared.standby.first { $0.id == id }?.name ?? id
        let confirmed = said.lowercased().contains("confirmed")

        observe(
            OwnerEventTypes.deviceWorked,
            .device,
            payload: [
                "device": name,
                "deviceId": id,
                "command": command == .on ? "on" : command == .off ? "off" : "press",
                "confirmed": confirmed ? "true" : "false",
                "by": "phone"
            ],
            confidence: confirmed ? 1 : 0.5,
            sensitivity: .low,
            key: "\(id)|\(command)|\(Int(Date().timeIntervalSince1970))")
    }

    /// The PC's lane. False when the PC could not be reached at all, so a fallback may try.
    /// Whether the last request to the PC certainly did not leave, or might have - programme §7B.
    ///
    /// Set by `askThePC` and read by the fallback. A field rather than a return value because
    /// `follow` answers one question - did this lane do it - and widening that for one caller
    /// would make every other lane carry a concept that is only about this one.
    private var lastDelivery: MobileCapabilities.Delivery = .neverSent

    private func askThePC(_ request: String, spoken: Bool) async -> Bool {
        thinking = true
        defer { thinking = false }

        // Nothing has left yet, so nothing can have happened at the other end.
        lastDelivery = .neverSent

        // A new question makes whatever was still coming for the last one stale.
        cancelVoiceWait()
        voice.stop()

        do {
            let client = try await session()

            // The session is open, so from here on a failure could be a reply lost on the way back
            // rather than a request that never went.
            lastDelivery = .unknown

            let reply = try await client.request("ask", ["text": request], timeout: 90)
            let said = reply.kind == "answer" ? (reply.text("text") ?? "") : reply.message
            lines.append(ChatLine(speaker: reply.kind == "answer" ? .jarvis : .system, text: said))
            LiveActivity.shared.answer = said
            // Whether to read it out is not this phone's decision alone. Its microphone hears the
            // same room the PC's does, so a wake word meant for the PC reaches both, and both
            // answering is the bug - with neither of them misbehaving on its own terms. The PC
            // arbitrates, and a phone that was not chosen still shows the whole conversation.
            if (speakAnswers || spoken) && mayReadAloud {
                if usePCVoice, reply.kind == "answer", reply.body["voice"] as? Bool == true {
                    expectVoice(for: reply.id, fallback: said)
                } else {
                    voice.say(said)
                }
            }
            return true
        } catch {
            return false
        }
    }

    // A turn the PC answered is filed by the PC, which knows what it did with it. Filing it here
    // as well would put two events in the timeline for one sentence - and the ids, being derived
    // from different nodes, would not deduplicate.

    /// Says something, in the transcript and aloud when this turn should be heard.
    ///
    /// Everything spoken on this phone goes through here and through `speak`, which is what makes
    /// the ladder in `MobileVoiceRouter` the only answer to "whose voice was that".
    private func answer(_ text: String, spoken: Bool) {
        lines.append(ChatLine(speaker: .jarvis, text: text))

        if speakAnswers || spoken { speak(text) }
    }

    /// Whether the phone's own voice may stand in when JARVIS's is not available - programme §4A.
    ///
    /// Off by default, and that is the point. A generic British voice answering in JARVIS's place
    /// is not a degraded JARVIS, it is a different assistant, and being surprised by it is worse
    /// than reading the words. The owner can turn it on if they would rather that than silence.
    @Published var systemVoiceAllowed = UserDefaults.standard.bool(forKey: "systemVoiceAllowed") {
        didSet { UserDefaults.standard.set(systemVoiceAllowed, forKey: "systemVoiceAllowed") }
    }

    /// The last route taken, for the settings page to show rather than for a log.
    @Published private(set) var lastVoiceRoute: VoiceRoute?

    /// The last phrase this PC rendered in JARVIS's voice, for the voice diagnostic - §9C.
    @Published private(set) var lastRenderedPhrase: String?

    /// What iOS says about notifications, read when the permission page asks - §20.
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// Whether the local network has been allowed. Nil until something has tried to use it.
    ///
    /// iOS gives no API for this, deliberately: there is no status to read, only the observable
    /// fact that a connection on the local network either worked or did not. So this is set by
    /// the bridge actually reaching the PC over a local address, which is the only honest source -
    /// and nil rather than false until then, because "not tried" and "refused" are different.
    @Published var localNetworkAllowed: Bool?

    /// Whether the microphone has been allowed, as iOS has it.
    @Published var microphoneAllowed = false

    /// The cloud question in flight, so the owner can stop it - priority §8B.
    private var cloudQuestion: Task<String, Never>?

    /// Whether there is something to stop, for the button to appear at all.
    var canStopThinking: Bool { cloudQuestion != nil }

    /// Stops the cloud question the owner is tired of waiting for - priority §8B.
    ///
    /// Recorded as a cancellation rather than a failure: the lane did nothing wrong, and marking a
    /// working provider broken because somebody changed their mind would then tell them to go and
    /// check a key that is fine.
    func stopThinking() {
        guard let question = cloudQuestion else { return }

        question.cancel()
        cloudQuestion = nil
        thinking = false
        CloudStatus.shared.stopped()
    }

    /// Reads what iOS currently says about the permissions JARVIS uses - priority §20.
    ///
    /// Asked for rather than remembered, every time the page opens: the owner changes something in
    /// Settings, iOS knows, and an app showing what it remembered is the exact failure the brief's
    /// "use OS truth" is about.
    func readPermissions() async {
        notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus

        microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted

        CloudStatus.shared.configured(CloudIntelligence.shared.isConfigured)
    }

    /// Notes that something on the local network either worked or did not - priority §20.
    ///
    /// iOS gives no status to read for this, so the only honest source is an attempt. Called by
    /// the bridge when it reaches the PC on a local address, and when it cannot.
    func localNetwork(reached: Bool) {
        // A granted permission is sticky, because that is what it is: once the owner has allowed
        // the local network, a later connection that fails is a network problem and not a refusal,
        // and reporting it as one would send them to Settings to fix nothing.
        if reached || localNetworkAllowed == nil { localNetworkAllowed = reached }
    }

    /// Why each rung of the voice ladder is or is not available - priority §9C.
    ///
    /// Assembled here rather than held, because every part of it belongs to something else: the
    /// cache knows what it holds, the link knows whether the PC is reachable, and the model
    /// transfer knows what arrived. A stored copy would be a fourth thing to keep in step.
    var voiceDiagnosis: VoiceDiagnosis {
        let transfer = VoiceModelStore.shared

        return VoiceDiagnosis(
            modelPresent: transfer.modelPresent,
            configPresent: transfer.configPresent,
            checksumValid: transfer.checksumValid,

            // Always false, and honestly so: Piper is C++ around onnxruntime and espeak-ng, and
            // neither is compiled into this app. The model transfers and nothing can speak it.
            runtimeAvailable: false,
            cachedPhrases: VoiceCache.shared.held,
            cachedBytes: VoiceCache.shared.bytes,
            lastRendered: lastRenderedPhrase,
            systemVoiceAllowed: systemVoiceAllowed,
            route: MobileVoiceRouter.route(
                "a phrase nothing has cached",
                able: MobileVoiceRouter.Able(
                    cached: nil,
                    onDevice: false,
                    pcAnswering: link.isOnline,
                    systemVoiceAllowed: systemVoiceAllowed,
                    speaking: true)))
    }

    /// Speaks one sentence by the best route available - programme §4A.
    func speak(_ text: String) {
        let able = MobileVoiceRouter.Able(
            cached: VoiceCache.shared.holds(text) ? text : nil,
            onDevice: false,
            pcAnswering: link.isOnline,
            systemVoiceAllowed: systemVoiceAllowed,
            speaking: true)

        let route = MobileVoiceRouter.route(text, able: able)
        lastVoiceRoute = route

        switch route {
        case .cached:
            guard let held = VoiceCache.shared.audio(for: text),
                  voice.play(wav: held.wav, mouth: held.mouth)
            else {
                // The index said it was there and the audio would not play. Fall to the next rung
                // rather than going silent, and the cache drops it on its next pass.
                if systemVoiceAllowed { voice.say(text) }
                return
            }

        case .onDevice:
            // Never chosen: `MobileVoiceRouter.whyNotOnDevice` says what is missing.
            if systemVoiceAllowed { voice.say(text) }

        case .fromThePC:
            // The PC renders and pushes it, in the same chunks an answer's voice arrives in, so
            // the receive machinery is the one that was already there.
            Task { await self.render(text) }

        case .systemVoice:
            voice.say(text)

        case .text:
            break
        }
    }

    /// Files a network transition, which explains a gap in what this phone reported.
    ///
    /// Programme §6: a phone that went into a tunnel and came out looks, from the PC, exactly like
    /// a phone that stopped working. One observation at each edge is the difference.
    func networkTransition(offline: Bool, cellular: Bool) {
        observe(
            OwnerEventTypes.network,
            .node,
            payload: [
                "node": "phone",
                "state": offline ? "offline" : (cellular ? "cellular" : "wifi")
            ],
            sensitivity: .low,
            key: "\(offline)|\(cellular)|\(Int(Date().timeIntervalSince1970 / 60))")
    }

    /// Files a turn held on this phone, so the PC knows the conversation happened.
    ///
    /// Programme §17 and §18: "give me three ideas" asked here and "let us use the second one"
    /// asked at the desk are one conversation, and the only way the desk can know that is if the
    /// turn travelled. Urgent by category, because the next turn may arrive at the other node.
    /// Files one turn into the shared conversation.
    ///
    /// `executor` names what actually carried the turn out when that is not this phone - a cloud
    /// provider, today. It is recorded rather than hidden because the PC's view of the
    /// conversation should say how each answer was reached, and because "which of these did a
    /// third party see" is a question the owner is entitled to be able to ask. The conversation and
    /// the response owner do not change: a provider is an executor, not another JARVIS.
    private func fileTurn(_ request: String, _ said: String, executor: String? = nil) {
        var payload = ["said": request, "answered": said, "conversation": conversationId]

        if let executor, !executor.isEmpty { payload["executor"] = executor }

        // Kept here as well, so a follow-up asked a moment later has its thread even with nothing
        // connected. Bounded, because this is context and not a transcript.
        turns.append((said: request, answered: said))
        if turns.count > 8 { turns.removeFirst(turns.count - 8) }

        observe(
            OwnerEventTypes.asked,
            .conversation,
            payload: payload,
            key: "\(request)|\(Int(Date().timeIntervalSince1970))")
    }

    /// This conversation's recent exchanges, for context that needs a thread.
    private var turns: [(said: String, answered: String)] = []

    var recentTurns: [(said: String, answered: String)] { turns }

    /// This phone's conversation, for a turn to belong to.
    ///
    /// One per launch. Finer than that would make every turn its own conversation and lose the
    /// reference that the handoff exists to resolve; coarser would tie a question asked this
    /// morning to an answer given last week.
    private(set) lazy var conversationId: String = UUID().uuidString

    /// This phone as a node: what it can do at this moment, as plain values.
    ///
    /// Read from the live models here and nowhere else, so `MobileCapabilities` stays a function of
    /// its argument and can be tested without an app, a PC or a network.
    var nodeState: MobileCapabilities.NodeState {
        MobileCapabilities.NodeState(
            pcName: wakeProfile.deviceName.isEmpty ? pcName : wakeProfile.deviceName,
            pcAnswering: link.isOnline,
            servicePaired: MachineLink.shared.isPaired,
            wakeEnabled: wakeProfile.enabled,
            wakeReachable: !WakeOnLanService.strategies(for: wakeProfile, cellular: network.cellular).isEmpty,
            hasOwnDeviceToken: SmartHomeModel.shared.credentials != nil,
            reachableDevices: SmartHomeModel.shared.standby.count,
            footageJoined: FootageModel.shared.credentials != nil,
            locationReporting: whereabouts.reporting,
            alertsOn: alertsTopic != nil,
            cloudReady: CloudIntelligence.shared.isConfigured)
    }

    /// What to say when asked what the PC is doing and JARVIS is not there to be asked.
    ///
    /// Spoken as the machine's own report rather than as a diagnosis: the service says what Windows
    /// is doing, and anything beyond that would be this phone guessing on its behalf.
    func machineAnswer() async -> String {
        guard MachineLink.shared.isPaired else {
            return MobilePhrases.cannotTellWithoutTheService()
        }

        guard let report = await MachineLink.shared.ask(force: true) else {
            return MobilePhrases.cannotReachAtAll(pcName)
        }

        switch report.session {
        case .nobodySignedIn:
            return MobilePhrases.nobodySignedIn(report.machine)
        case .locked:
            return report.desktopRunning
                ? MobilePhrases.lockedWithJarvisRunning(report.machine)
                : MobilePhrases.lockedWithoutJarvis(report.machine)
        case .inUse:
            return report.desktopRunning
                ? MobilePhrases.awakeWithJarvisRunning(report.machine)
                : MobilePhrases.awakeWithoutJarvis(report.machine)
        case .unknown:
            return MobilePhrases.onButCannotSay(report.machine)
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

    /// Asks the PC to render one sentence in JARVIS's voice - programme §4A.
    ///
    /// For the sentences this phone composes itself. Before this the local path spoke in the
    /// phone's own voice however awake the PC was, because a render only ever rode an answer the
    /// PC had given - so switching a light from the phone sounded like a different assistant.
    func render(_ text: String) async {
        guard link.isOnline, let client = try? await session() else { return }

        do {
            let reply = try await client.request("voice.render", ["text": text])

            // Armed after the reply, which is what the answer path does and is safe for the same
            // reason: `receiveVoice` buffers pushes under their request id whether anything is
            // waiting or not, so a render that arrives first is still assembled.
            expectVoice(for: reply.id, fallback: systemVoiceAllowed ? text : "")
        } catch {
            // Nothing is waiting, so nothing needs cancelling. The words are already on screen.
            if systemVoiceAllowed { voice.say(text) }
        }
    }

    /// Fills the phrase cache from the PC, so JARVIS's own voice survives the desk going to sleep.
    ///
    /// A handful of sentences at a time rather than all of them at once: this runs on a
    /// connection the owner did not ask for, and a burst of twenty renders would be noticeable on
    /// a PC that is doing something. The rest arrive on later connections, which is soon enough
    /// for a cache whose whole purpose is to be ready next week.
    func warmTheVoiceCache() async {
        guard link.isOnline, !VoiceCache.shared.voiceId.isEmpty else { return }

        let wanted = VoiceCache.shared.missing().prefix(3)

        for kind in wanted {
            await render(kind.words)

            // Rendered one at a time: the push machinery tracks one outstanding render, and two
            // at once would have the second overwrite the first's wait.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

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

        // Kept before playing, so a sentence JARVIS says often is in its own voice next time even
        // with the PC asleep - programme §4C. Keyed on the words and the voice together, so
        // changing the voice orphans the old audio rather than serving it.
        VoiceCache.shared.keep(wait.text, wav: wav, mouth: entry.mouth)
        lastRenderedPhrase = wait.text

        if !voice.play(wav: wav, mouth: entry.mouth), systemVoiceAllowed { voice.say(wait.text) }
    }

    private func voiceUnavailable(_ id: String) {
        guard let wait = voiceWait, wait.id == id else { return }
        voiceParts[id] = nil
        cancelVoiceWait()

        // An empty fallback means the caller has already decided the words are to be shown rather
        // than spoken by a voice that is not JARVIS's.
        if !wait.text.isEmpty { voice.say(wait.text) }
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
        // Asked for on purpose, so whatever failed before is no longer a reason not to try.
        lastLiveFailure = nil

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

    /// Face ID, then the PC sends what the camera is already seeing.
    ///
    /// It will refuse if nothing is looking through the camera, and that refusal is passed on
    /// rather than worked around: the camera has one owner, and a page being opened on a phone is
    /// not a reason to take it from the security watcher.
    func startWatchingCamera() async {
        do {
            let client = try await session()
            let body: [String: Any] = ["network": network.cellular ? "cellular" : "wifi"]
            var reply = try await client.request("camera.live.start", body)

            if reply.kind != "done" && reply.message.contains("Face ID") {
                reply = try await client.approvedRequest("camera.live.start", reason: "Watch your PC's camera", body)
            }

            if reply.kind == "done" {
                cameraFrame = nil
                newestCameraFrame = -1
                watchingCamera = true
            } else {
                toast = reply.message
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func stopWatchingCamera() async {
        watchingCamera = false
        cameraFrame = nil
        _ = try? await client?.request("camera.live.stop")
    }

    /// Decoded off the main thread, and a frame that finishes decoding after a newer one is dropped.
    private func receiveCameraFrame(_ message: BridgeMessage) {
        guard watchingCamera,
              let sequence = (message.body["sequence"] as? NSNumber)?.intValue,
              let jpeg = message.text("jpeg"), let data = Data(base64Encoded: jpeg) else { return }

        Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data)?.preparingForDisplay() else { return }
            await MainActor.run {
                let model = AppModel.shared
                guard model.watchingCamera, sequence > model.newestCameraFrame || sequence == 0 else { return }
                model.newestCameraFrame = sequence
                model.cameraFrame = image
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

    /// Puts away the picture of whoever was at the PC.
    ///
    /// It had no way out. The picture appeared whenever one arrived and stayed on the security
    /// screen for as long as the app was running, so having looked at it once there was nothing to
    /// do but scroll past it. Dismissing is only about this screen - the event, its photographs and
    /// its recording are all still on the PC.
    func dismissChallengePhoto() {
        challengePhoto = nil
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

        // Not straight after one that failed. The owner pressing Watch is always allowed; a network
        // change quietly trying again is what turns one failure into a loop.
        if let failed = lastLiveFailure, Date().timeIntervalSince(failed) < Self.afterALiveFailure { return }

        Task { await startLive(display) }
    }

    /// How long a failed live view stops the network-change restart from trying again.
    nonisolated static let afterALiveFailure: TimeInterval = 60

    /// When live view last ended with a reason from the PC.
    private var lastLiveFailure: Date?

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
        if message.kind == "camera.frame" { receiveCameraFrame(message); return }
        if message.kind == "file.data" { ControlModel.shared.receiveFileData(message); return }
        if message.kind == "notice" { receiveNotice(message); return }
        if message.kind == "devices.changed" { SmartHomeModel.shared.receive(message); return }
        if message.kind == "learning.changed" { LearningModel.shared.receive(message); return }
        if message.kind == "audio.frame" {
            if hearingPC, let pcm = message.text("pcm").flatMap({ Data(base64Encoded: $0) }) { pcAudio.play(pcm) }
            return
        }
        if message.kind == "security.photo" { receiveSecurityPhoto(message); return }
        if message.kind == "screen.ended" {
            // Remembered, and that matters: the network changing restarts a running stream, and on
            // mobile data it changes often. A display the PC cannot read would be asked for again
            // every few seconds, each attempt ending the same way - which is what the owner saw as
            // the PC connection dropping over and over while they tried to use it.
            lastLiveFailure = Date()

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

        // The service's pairing goes with it. It is the same machine, and forgetting the PC throws
        // away the Secure Enclave keys both pairings are built on, so leaving the service's record
        // behind would leave a key that can no longer be used and a row that can never connect.
        MachineLink.shared.forget()
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
        showcasing = true
        link = .online(pcName)
        lines = script.map { ChatLine(speaker: $0.0, text: $0.1) }
    }
}
#endif
