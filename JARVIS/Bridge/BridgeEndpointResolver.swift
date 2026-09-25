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

    /// And how long one gets on mobile data, where two and a half seconds was never enough.
    ///
    /// The number is short because the list is long, and on mobile data the list is not long: every
    /// local address has already been dropped as unreachable, so what is left is the handful of
    /// private-network addresses. Spending longer on each costs nothing, because there is nothing
    /// else to spend it on - and it has to be longer, since the radio bringing a data context up
    /// and a VPN tunnel being established on demand are both slower than a handshake on a LAN.
    static let perCandidateOnCellular: TimeInterval = 8

    /// What one candidate gets, given where the phone is.
    static func patience(cellular: Bool) -> TimeInterval {
        cellular ? perCandidateOnCellular : perCandidate
    }

    /// Whether a host is an address rather than a name, and so needs nothing resolved.
    static func isLiteralAddress(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

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
        for host in pc.localHosts ?? [] where host != pc.host {
            local.append(BridgeCandidate(
                name: host, source: .lastKnownLocal,
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                describedAs: "\(host):\(pc.port)"))
        }

        if cellular {
            // A home address cannot answer from mobile data. Including it would spend the timeout
            // on something that cannot work.
            //
            // Numbers before names, but never before what the owner typed.
            //
            // A private network's addresses are fixed and need nothing looked up; its name needs
            // the tunnel's own resolver, which on mobile data is one more thing to be brought up
            // before anything can be tried. Both are offered - the name is what survives an address
            // changing - but the one that cannot be delayed by DNS goes first, because each attempt
            // here is given eight seconds rather than two and a half.
            //
            // The owner's own address stays at the front regardless. Somebody who went to the
            // trouble of typing one meant it, and sorting it behind a number the PC volunteered
            // would quietly overrule them - which a first attempt at this did.
            //
            // Partitioned rather than sorted, because Swift's sort is not stable: two names would
            // come back in whatever order it liked, which is a different list on different days.
            let typed = privateOnes.filter { $0.name == pc.remoteHost }
            let said = privateOnes.filter { $0.name != pc.remoteHost }

            found += typed
                + said.filter { isLiteralAddress($0.name) }
                + said.filter { !isLiteralAddress($0.name) }
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

    /// Where the same machine's pre-login service might be, in the order worth trying.
    ///
    /// The same addresses as the PC, on the service's own port. Built from the PC's record rather
    /// than from a second list, because it is the same machine: one list that the PC keeps up to
    /// date beats two, one of which would go stale.
    ///
    /// Bonjour is left out, and not by oversight. What the PC advertises is desktop JARVIS - the
    /// name resolves to the desktop's port - so a Bonjour candidate here would dial the desktop and
    /// present the service's key to it, which is exactly the confusion pinning exists to catch. The
    /// service is reached by address, or not at all.
    static func serviceCandidates(
        for pc: PairedPC,
        port: UInt16,
        cellular: Bool,
        preferLocal: Bool = true
    ) -> [BridgeCandidate] {
        var machine = pc
        machine.port = port
        machine.serviceName = nil

        return candidates(for: machine, discovered: [], cellular: cellular, preferLocal: preferLocal)
    }
}
