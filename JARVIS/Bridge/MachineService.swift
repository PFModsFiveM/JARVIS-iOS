import Foundation
import Network
import UIKit

/// The PC's pre-login service: the same machine, a different door.
///
/// Desktop JARVIS only exists once somebody has signed in. The service runs from boot, as
/// LocalSystem, and answers three read-only things - what the machine is, what its session is
/// doing, and whether the desktop is up. It is what makes "is my PC on, or just locked?" a question
/// this phone can answer instead of guessing from a connection that did not come up.
///
/// It is a second pairing, not a second PC. The keys are different on purpose: the PC's desktop key
/// is sealed to the owner's Windows account, and a service running before anybody has signed in
/// cannot open it. So the service has its own, and this phone pins both.
enum MachineService {
    /// Next to the desktop's 47823, never the same as it.
    ///
    /// Two processes cannot hold one port, and which of them got it would depend on which started
    /// first - so a phone could never know what it had reached. With two, which one answers is
    /// itself the answer to whether anybody is signed in.
    static let defaultPort: UInt16 = 47824
}

/// What the service says about the machine.
struct MachineReport: Equatable {
    /// What Windows is doing. The service will not say who is signed in, only whether somebody is.
    enum Session: String, Equatable {
        case nobodySignedIn = "NobodySignedIn"
        case locked = "Locked"
        case inUse = "InUse"
        case unknown = "Unknown"
    }

    let machine: String
    let session: Session

    /// The service's own sentence for it, used rather than one written here so that the phone and
    /// the PC's log always say the same thing.
    let described: String

    /// Whether desktop JARVIS would answer. Not the same as the machine being on, which is the
    /// distinction this whole endpoint exists to draw.
    let desktopRunning: Bool

    let at: Date

    /// A line for the PC's row in Home: what somebody would want to know before pressing anything.
    var summary: String {
        switch session {
        case .nobodySignedIn: return "On, nobody signed in"
        case .locked: return desktopRunning ? "Locked" : "Locked, JARVIS not running"
        case .inUse: return desktopRunning ? "Awake" : "Awake, JARVIS not running"
        case .unknown: return "On"
        }
    }

    /// Reads a `status` reply. Nil when it is not one, so an older or unexpected answer is ignored
    /// rather than shown as a machine in an unknown state.
    static func read(_ body: [String: Any], at: Date = Date()) -> MachineReport? {
        guard let machine = body["machine"] as? String, !machine.isEmpty,
              let session = (body["session"] as? String).flatMap(Session.init(rawValue:))
        else { return nil }

        return MachineReport(
            machine: machine,
            session: session,
            described: body["described"] as? String ?? session.rawValue,
            desktopRunning: (body["desktop"] as? String) == "online",
            at: at)
    }
}

/// The service this phone has paired with, and the key it must present.
///
/// Where to reach it comes from the `PairedPC` record rather than being kept again here: it is the
/// same machine, with the same addresses, and two copies of a list that the PC updates over the
/// bridge would mean one of them going stale.
struct PairedService: Codable, Equatable {
    var deviceId: String
    var serverKey: Data
    var port: UInt16 = MachineService.defaultPort

    var fingerprint: String { Data(SHA256Hash.of(serverKey).prefix(4)).hex }

    private static let account = "paired-service"

    static func load() -> PairedService? {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(PairedService.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.write(Self.account, data) }
    }

    static func forget() { Keychain.delete(account) }
}

/// Asking the machine what it is doing when JARVIS itself cannot be asked.
///
/// **It connects, asks, and hangs up.** The service answers three read-only things and is asked
/// rarely - when the desktop did not come up, and when somebody is looking at the Home panel - so a
/// held-open connection would buy nothing and leave a standing door into a machine that nobody is
/// signed in to. The desktop's connection is the one worth keeping alive, because it carries
/// conversation; this one carries a sentence.
///
/// **It never speaks first.** Pushes are ignored: there is nothing the pre-login service is allowed
/// to ask this phone to do, and treating anything it sent as an instruction would be the beginning
/// of the general privileged channel this deliberately is not.
@MainActor
final class MachineLink: ObservableObject {
    static let shared = MachineLink()

    /// The pairing, or nil when the service has never been paired with.
    @Published private(set) var paired: PairedService? = PairedService.load()

    /// The last thing the service said, and when.
    @Published private(set) var report: MachineReport?

    /// Why the last attempt did not produce one. Nil while it is working.
    @Published private(set) var problem: String?

    @Published private(set) var asking = false

    /// The six digits during pairing, compared against the ones the PC's console prints.
    @Published var pairingDigits: String?

    private let model: AppModel

    init(model: AppModel = .shared) {
        self.model = model
    }

    /// How stale an answer may be before asking again. Long enough that opening the Home panel
    /// twice does not open two connections; short enough that a machine that has just been woken
    /// stops saying it is off.
    static let freshFor: TimeInterval = 20

    var isPaired: Bool { paired != nil }

    /// Asks the service, unless the last answer is still fresh.
    @discardableResult
    func ask(force: Bool = false) async -> MachineReport? {
        if !force, let report, Date().timeIntervalSince(report.at) < Self.freshFor { return report }
        guard !asking, let paired, let pc = model.pc else { return nil }

        asking = true
        defer { asking = false }

        let cellular = model.network.cellular
        let candidates = BridgeEndpointResolver.serviceCandidates(
            for: pc, port: paired.port, cellular: cellular, preferLocal: pc.preferLocal ?? true)

        guard !candidates.isEmpty else {
            problem = "No address to try the service on yet."
            return nil
        }

        for candidate in candidates {
            let client = BridgeClient(
                endpoint: candidate.endpoint,
                connectWithin: BridgeEndpointResolver.patience(cellular: cellular),
                patientWhileWaiting: cellular)

            do {
                _ = try await client.resume(deviceId: paired.deviceId, pinnedServerKey: paired.serverKey)
                let reply = try await client.request("status", timeout: 10)
                await client.close()

                guard let read = MachineReport.read(reply.body) else {
                    problem = "The service answered something unexpected."
                    continue
                }

                report = read
                problem = nil
                return read
            } catch {
                await client.close()

                // A service that refuses this phone will refuse it on every address, because the
                // identity it is refusing is the same one each time.
                if (error as? BridgeError)?.needsPairingAgain == true {
                    problem = error.localizedDescription
                    return nil
                }
            }
        }

        // Nothing answered. Said as what it means rather than as a list of failures: if neither the
        // desktop nor the service can be reached, the machine is off or not on this network.
        problem = "The machine isn't answering at all."
        report = nil
        return nil
    }

    /// Forgets what the service last said. Used when the machine has been asked to change state, so
    /// the panel does not keep showing the answer from before the change.
    func stale() {
        report = nil
    }

    // MARK: pairing

    /// Pairs with the service, on the same machine the phone is already paired with.
    ///
    /// The desktop first, always: the service's addresses come from that record, and pairing with a
    /// machine's pre-login endpoint before having ever spoken to the machine itself would mean
    /// pinning a key for something nobody had confirmed was theirs.
    func pair(code: String, host typed: String? = nil) async {
        guard let pc = model.pc else {
            problem = "Pair with the PC first; the service is the same machine."
            return
        }

        pairingDigits = nil

        let port = MachineService.defaultPort
        let endpoints: [NWEndpoint]

        if let typed, !typed.isEmpty, let wire = NWEndpoint.Port(rawValue: port) {
            endpoints = [.hostPort(host: NWEndpoint.Host(typed), port: wire)]
        } else {
            endpoints = BridgeEndpointResolver.serviceCandidates(
                for: pc, port: port, cellular: model.network.cellular,
                preferLocal: pc.preferLocal ?? true).map(\.endpoint)
        }

        guard !endpoints.isEmpty else {
            problem = "No address to pair with. Type the PC's address."
            return
        }

        var last: Error = BridgeError.closed

        for endpoint in endpoints {
            let client = BridgeClient(endpoint: endpoint, connectWithin: 6)

            do {
                let result = try await client.pair(code: code, deviceName: UIDevice.current.name) { digits in
                    Task { @MainActor in MachineLink.shared.pairingDigits = digits }
                }

                let service = PairedService(deviceId: result.deviceId, serverKey: result.serverKey, port: port)
                service.save()
                paired = service
                pairingDigits = nil
                problem = nil
                model.toast = "Paired with the service. Its key is \(service.fingerprint)."
                await ask(force: true)
                return
            } catch {
                await client.close()
                last = error

                // A declined or wrong code is an answer, not an address to move on from: the next
                // address is the same service, and it would only decline again.
                if let bridge = error as? BridgeError, case .pairingDeclined = bridge { break }
            }
        }

        pairingDigits = nil
        problem = last.localizedDescription
    }

    func forget() {
        PairedService.forget()
        paired = nil
        report = nil
        problem = nil
    }
}
