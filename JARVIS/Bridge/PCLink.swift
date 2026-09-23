import Combine
import CryptoKit
import Foundation
import Network

/// What JARVIS advertises itself as, and where it listens by default. Must match the PC's MobileBridge settings.
enum JarvisService {
    static let type = "_jarvis._tcp"
    static let domain = "local."
    static let defaultPort: UInt16 = 47823
}

/// The PC this phone is paired with: how to reach it and the key it must present. Kept in the Keychain.
struct PairedPC: Codable, Equatable {
    var deviceId: String
    var serverKey: Data
    /// The Bonjour name ("JARVIS DESKTOP"), when it was found that way.
    var serviceName: String?
    /// An address typed by hand, used first when present.
    var host: String?
    var port: UInt16
    /// Where the PC is reachable away from home - its Tailscale address (100.x.y.z) or name. Tried after the home
    /// address, or first on mobile data. Nil until set in Settings or told by the PC.
    var remoteHost: String?

    /// Every private-network address the PC has told this phone about, best first.
    ///
    /// The PC knows its own addresses exactly and the bridge has already proved which PC it is, so
    /// it says and this saves (see `AppModel.learnNetwork`). What used to happen instead: the owner
    /// found the address on another screen, typed it into Settings, and typed it again when it
    /// changed - or did not, and the app stopped working away from home without saying why.
    var remoteHosts: [String]?

    /// Every local address the PC has told this phone about. Used when Bonjour cannot see it.
    var localHosts: [String]?

    /// The owner's setting: at home, use the home network rather than going round by Tailscale.
    var preferLocal: Bool?

    var fingerprint: String {
        Data(SHA256Hash.of(serverKey).prefix(4)).hex
    }

    var endpoint: NWEndpoint {
        if let host, !host.isEmpty, let port = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return .service(name: serviceName ?? "", type: JarvisService.type, domain: JarvisService.domain, interface: nil)
    }

    /// The PC away from home, when an address for it has been set.
    var remoteEndpoint: NWEndpoint? {
        guard let host = remoteEndpoints.first, let port = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    /// Every way to reach the PC from anywhere, best first: what the owner typed, then what the PC
    /// said. Typed first deliberately - somebody who has gone to the trouble meant it.
    var remoteEndpoints: [String] {
        var hosts: [String] = []
        if let remoteHost, !remoteHost.isEmpty { hosts.append(remoteHost) }
        for host in remoteHosts ?? [] where !host.isEmpty && !hosts.contains(host) { hosts.append(host) }
        return hosts
    }

    private static let account = "paired-pc"

    static func load() -> PairedPC? {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(PairedPC.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.write(Self.account, data) }
    }

    static func forget() {
        Keychain.delete(account)
        WakeProfile.forget()
        DeviceKeys.erase()
    }
}

enum SHA256Hash {
    static func of(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

/// A JARVIS PC advertising itself on the Wi-Fi.
struct FoundPC: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }

    static func == (lhs: FoundPC, rhs: FoundPC) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// Finds PCs running JARVIS with the iPhone bridge on. iOS asks the first time for Local Network access.
@MainActor
final class PCBrowser: ObservableObject {
    @Published private(set) var found: [FoundPC] = []
    @Published private(set) var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: JarvisService.type, domain: JarvisService.domain), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let pcs = results.compactMap { result -> FoundPC? in
                if case let .service(name, _, _, _) = result.endpoint { return FoundPC(name: name, endpoint: result.endpoint) }
                return nil
            }
            Task { @MainActor in self?.found = pcs.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error), .waiting(let error):
                    self?.problem = "Can't search the network (\(error.localizedDescription)). Check Settings › Privacy › Local Network › JARVIS, or type the PC's address."
                case .ready:
                    self?.problem = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
