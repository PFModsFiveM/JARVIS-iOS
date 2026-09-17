import CryptoKit
import Foundation
import Network

/// The PC this phone is paired with: how to reach it and the key it must present. Kept in the Keychain.
struct PairedPC: Codable, Equatable {
    var deviceId: String
    var serverKey: Data
    /// The Bonjour name ("JARVIS DESKTOP"), when it was found that way.
    var serviceName: String?
    /// An address typed by hand, used first when present.
    var host: String?
    var port: UInt16

    var fingerprint: String {
        Data(SHA256Hash.of(serverKey).prefix(4)).hex
    }

    var endpoint: NWEndpoint {
        if let host, !host.isEmpty, let port = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return .service(name: serviceName ?? "", type: PCBrowser.serviceType, domain: "local.", interface: nil)
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
    static let serviceType = "_jarvis._tcp"

    @Published private(set) var found: [FoundPC] = []
    @Published private(set) var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: .tcp)
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
