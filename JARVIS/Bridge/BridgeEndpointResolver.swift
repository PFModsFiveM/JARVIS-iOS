import Foundation
import Network

/// One way to reach the PC, and what it is good for.
struct BridgeCandidate: Identifiable, Equatable {
    enum Source: String, Equatable {
        /// Found on this network by Bonjour, right now.
        case discovered
        /// The address this phone last reached the PC at on a local network.
        case lastKnownLocal
        /// A private network that follows the PC around - Tailscale. Works from anywhere.
        case privateNetwork
        /// Something the owner typed, or the PC named that is neither of the above.
        case configured
    }

    var name: String
    var source: Source
    var endpoint: NWEndpoint
    /// What to say in the log and on the diagnostics screen. Never a key.
    var describedAs: String

    var id: String { describedAs }

    static func == (lhs: BridgeCandidate, rhs: BridgeCandidate) -> Bool {
        lhs.describedAs == rhs.describedAs && lhs.source == rhs.source
    }
}

/// Where the PC might be, in the order worth trying, given where this phone is.
///
/// This used to be two entries and a coin toss: the home address, and an away-from-home address the
/// owner had typed in, ordered by whether the phone was on mobile data. That is wrong in both
/// directions. On a café's Wi-Fi the phone is not on cellular, so the home address went first and
/// nothing reached it. On mobile data with no address typed there was nothing to try at all.
///
/// So: the PC hands the phone every address it has over the already-encrypted bridge while the
/// phone is at home (`network`), the phone saves them, and this puts them in order. The private
/// network comes first whenever the phone is not demonstrably at home, because it is the one that
/// works from anywhere.
enum BridgeEndpointResolver {
    /// How long one candidate gets before the next is tried.
    ///
    /// Short on purpose. A local address that is not reachable from this network does not fail - the
    /// connection simply waits - so this is what turns "waiting for ever" into "try the next one".
    /// Two and a half seconds is far longer than a TCP handshake needs on a LAN or over Tailscale,
    /// and short enough that walking through the whole list is still quick.
    static let perCandidate: TimeInterval = 2.5

    /// Everything worth trying, best first.
    ///
    /// - Parameters:
    ///   - pc: the paired PC, with whatever it has told this phone about itself.
    ///   - discovered: what Bonjour can see on this network this instant.
    ///   - cellular: whether the only way out is mobile data.
    ///   - preferLocal: the owner's setting. On, a discovered PC on this very network wins outright.
    static func candidates(
        for pc: PairedPC,
        discovered: [FoundPC],
        cellular: Bool,
        preferLocal: Bool = true
    ) -> [BridgeCandidate] {
        guard let port = NWEndpoint.Port(rawValue: pc.port) else { return [] }
        var found: [BridgeCandidate] = []

        // Bonjour, when it can see the PC. This is proof the phone is on the same network as the PC
        // rather than a guess about it, which is why it outranks everything else.
        if !cellular, let service = discovered.first(where: { $0.name == pc.serviceName }) ?? discovered.first {
            found.append(BridgeCandidate(
                name: service.name, source: .discovered, endpoint: service.endpoint,
                describedAs: "\(service.name) (found on this network)"))
        }

        // The private network. First whenever the phone is not demonstrably at home: it works from
        // anywhere, including from a Wi-Fi that is not the owner's.
        let privateOnes = pc.remoteEndpoints.map { host in
            BridgeCandidate(
                name: host, source: .privateNetwork,
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                describedAs: "\(host):\(pc.port)")
        }

        // The home address, when there is one. Tried on Wi-Fi even when Bonjour saw nothing - the
        // browser needs Local Network permission and the address does not.
        var local: [BridgeCandidate] = []
        if let host = pc.host, !host.isEmpty {
            local.append(BridgeCandidate(
                name: host, source: .lastKnownLocal,
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                describedAs: "\(host):\(pc.port)"))
        }
        for host in pc.localHosts where host != pc.host {
            local.append(BridgeCandidate(
                name: host, source: .lastKnownLocal,
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                describedAs: "\(host):\(pc.port)"))
        }

        if cellular {
            // A home address cannot answer from mobile data. Including it would spend the timeout
            // on something that cannot work.
            found += privateOnes
        } else if preferLocal && !found.isEmpty {
            found += local + privateOnes
        } else {
            found += privateOnes + local
        }

        // Bonjour by name, as a last resort: it resolves only on the PC's own network, and only with
        // Local Network permission, but it is the one candidate that still works when every address
        // the PC has has changed.
        if !cellular, let name = pc.serviceName, !name.isEmpty, !found.contains(where: { $0.source == .discovered }) {
            found.append(BridgeCandidate(
                name: name, source: .discovered,
                endpoint: .service(name: name, type: JarvisService.type, domain: JarvisService.domain, interface: nil),
                describedAs: "\(name) (Bonjour)"))
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0.describedAs).inserted }
    }
}
