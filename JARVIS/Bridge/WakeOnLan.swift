import Foundation
import Network

/// A machine's network card, said the way a magic packet needs it.
///
/// Six bytes. Not a string: every way people write a MAC - dashes, colons, bare hex, either case -
/// is the same six bytes, and keeping the string would mean every reader parsing it again and one
/// of them getting it wrong.
struct MacAddress: Equatable, Codable, CustomStringConvertible {
    static let byteCount = 6

    let bytes: [UInt8]

    /// Reads a MAC in any of the ways people write one, or fails.
    ///
    /// Accepted: `04-7C-16-4E-A7-F5`, `04:7C:16:4E:A7:F5`, `04.7C.16.4E.A7.F5`, `047C164EA7F5`, in
    /// either case, with spaces around it. Refused: anything that is not exactly twelve hexadecimal
    /// digits once the separators are taken out, and anything using more than one kind of separator,
    /// which is nearly always a typed address that lost a character.
    ///
    /// The all-zero address is refused too. It parses perfectly and wakes nothing, which is the
    /// worst way for this to fail: a packet sent, a wake that never comes, and nothing to say why.
    init?(_ text: String?) {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = Set(trimmed.filter { $0 == "-" || $0 == ":" || $0 == "." })
        guard separators.count <= 1 else { return nil }

        let digits = separators.first.map { separator in String(trimmed.filter { $0 != separator }) } ?? trimmed
        guard digits.count == Self.byteCount * 2 else { return nil }

        var parsed: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            parsed.append(byte)
            index = next
        }

        guard parsed.contains(where: { $0 != 0 }) else { return nil }
        bytes = parsed
    }

    /// The address as the router's page and the card's properties write it: dashes, upper case.
    var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: "-")
    }

    /// The magic packet: six 0xFF bytes, then the address sixteen times.
    ///
    /// The pattern is deliberately unmistakable so it cannot occur by accident in ordinary traffic.
    /// The card stays powered while the machine sleeps, watching every frame that reaches it for
    /// this pattern naming its own address.
    var magicPacket: Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }
}

/// Which way a wake request went.
enum WakeStrategy: String, Codable {
    /// To the home network's broadcast address. Only works from inside the house.
    case localBroadcast
    /// To the home connection's public address, for the router to forward inwards.
    case remoteRouter
}

/// Where the PC can be woken, and whether it may be.
///
/// Everything here except the remote host is read off the PC itself and handed over the encrypted
/// bridge while the phone is at home (`BridgeClient.network()`), so it is not typed by anybody. The
/// remote host is the one fact the PC cannot know: it is about the owner's router and their
/// internet connection.
struct WakeProfile: Codable, Equatable {
    var deviceName: String
    var mac: MacAddress?
    /// The home network's broadcast address, e.g. 192.168.1.255.
    var broadcast: String
    var port: UInt16
    /// A dynamic-DNS name for the home connection, or its public address. Empty means home only.
    var remoteHost: String
    /// The port the router forwards to the home broadcast address.
    var remotePort: UInt16
    var enabled: Bool
    /// Whether a wake may be sent over mobile data at all. On: the whole point of remote wake.
    var overCellular: Bool
    var lastAttempt: Date?

    /// Whether the card address came from the owner rather than from the PC.
    ///
    /// Kept so that the next connection does not overwrite it. Optional in the stored shape because
    /// profiles saved before this existed have no such key, and a phone that has been paired for a
    /// month should not lose its wake settings to a new field.
    var typedByHand: Bool? = nil

    static let `default` = WakeProfile(
        deviceName: "PC", mac: nil, broadcast: "", port: 9,
        remoteHost: "", remotePort: 40009, enabled: true, overCellular: true, lastAttempt: nil)

    /// Whether there is enough here to send anything at all.
    var usable: Bool { enabled && mac != nil && !broadcast.isEmpty }

    /// Whether this PC can be woken from outside the house.
    var reachableRemotely: Bool { enabled && mac != nil && !remoteHost.isEmpty }

    private static let account = "wake-profile"

    static func load() -> WakeProfile {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(WakeProfile.self, from: $0) } ?? .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { Keychain.write(Self.account, data) }
    }

    static func forget() { Keychain.delete(account) }
}

/// What happened when a wake request was sent. Never whether the machine woke.
struct WakeOutcome: Equatable {
    var sent: Bool
    var strategy: WakeStrategy
    var destination: String
    var packets: Int
    /// One sentence a person can read. Empty when it worked.
    var because: String

    static func failed(_ strategy: WakeStrategy, _ destination: String, _ because: String) -> WakeOutcome {
        WakeOutcome(sent: false, strategy: strategy, destination: destination, packets: 0, because: because)
    }
}

/// Waking the PC while it is asleep.
///
/// **Out of band, and that is the whole point.** Nothing here talks to JARVIS, needs the bridge,
/// needs anybody logged in on the PC or needs the PC to be running - it cannot, because the machine
/// it is waking is asleep. It holds a profile and a socket and nothing else.
///
/// Sending is the whole of what it does. Whether the PC woke is learnt afterwards, by the bridge
/// becoming reachable - which is why `WakeOutcome` has no field that could claim otherwise, and why
/// the word throughout is "sent".
actor WakeOnLanService {
    /// How many packets one wake request sends.
    ///
    /// Three, spaced a moment apart. UDP loses packets and nothing acknowledges this one, so a
    /// single send that goes missing is a button that did nothing; three is enough that losing all
    /// of them means something else is wrong. Not more, and not repeated: a machine that did not
    /// wake will not wake on the ninetieth packet either, and a button that quietly keeps shouting
    /// at a home router is how a connection ends up rate-limited.
    static let burst = 3

    /// The pause between the packets of one burst.
    static let betweenPackets: Duration = .milliseconds(120)

    /// Puts the bytes on the network. A seam, so the tests prove exactly what would go out and where
    /// without a socket, and nothing in the suite ever broadcasts on the machine it runs on.
    typealias Send = @Sendable (Data, String, UInt16) async throws -> Void

    private let send: Send

    init(send: @escaping Send = WakeOnLanService.udp) {
        self.send = send
    }

    /// Which way to send, given where the phone is and what has been set up.
    ///
    /// Deliberately not the Wi-Fi network's name. iOS will not hand that over without location
    /// permission, and asking for the owner's location to decide how to send a wake packet is a
    /// trade nobody would take. What the phone can always see is which kind of interface carries
    /// its traffic, which answers the only question that matters: can a broadcast to the home
    /// network's address possibly reach it.
    ///
    /// On Wi-Fi it is worth trying the broadcast first even on a network that is not home - it
    /// fails in milliseconds and costs nothing, where the remote route crosses the internet. On
    /// mobile data a local broadcast cannot work at all, so it is not attempted.
    static func strategies(for profile: WakeProfile, cellular: Bool) -> [WakeStrategy] {
        var order: [WakeStrategy] = []

        if !cellular && profile.usable { order.append(.localBroadcast) }
        if profile.reachableRemotely && (!cellular || profile.overCellular) { order.append(.remoteRouter) }

        return order
    }

    /// Sends a wake request one way.
    func wake(_ profile: WakeProfile, using strategy: WakeStrategy) async -> WakeOutcome {
        let host = strategy == .localBroadcast ? profile.broadcast : profile.remoteHost
        let port = strategy == .localBroadcast ? profile.port : profile.remotePort
        let destination = "\(host):\(port)"

        guard profile.enabled else {
            return .failed(strategy, destination, "Waking \(profile.deviceName) is switched off.")
        }
        guard let mac = profile.mac else {
            return .failed(strategy, destination, "\(profile.deviceName) has no MAC address, so there is nothing to wake. Connect to it once at home and it will tell this phone.")
        }
        guard !host.isEmpty else {
            return .failed(strategy, destination, strategy == .localBroadcast
                ? "No broadcast address for the home network."
                : "No way in from outside is set, so \(profile.deviceName) can only be woken from home.")
        }
        guard port > 0 else { return .failed(strategy, destination, "\(port) is not a port.") }

        let packet = mac.magicPacket
        var sent = 0

        for attempt in 0..<Self.burst {
            if attempt > 0 { try? await Task.sleep(for: Self.betweenPackets) }
            do {
                try await send(packet, host, port)
                sent += 1
            } catch {
                // The first failure is the answer: a name that will not resolve resolves no better
                // twice, and a network with no route to that address has none on the second try.
                return .failed(strategy, destination, Self.explain(error, profile, strategy))
            }
        }

        return WakeOutcome(sent: true, strategy: strategy, destination: destination, packets: sent, because: "")
    }

    /// Tries each way this phone can reach the PC, best first, and stops at the first that sends.
    ///
    /// "Sends", not "wakes": there is no way to tell from here. A local broadcast that left the
    /// phone is as much as this can know, and if the PC does not appear the caller falls through to
    /// its own timeout rather than this shouting again.
    func wake(_ profile: WakeProfile, cellular: Bool) async -> WakeOutcome {
        let order = Self.strategies(for: profile, cellular: cellular)

        guard !order.isEmpty else {
            return .failed(cellular ? .remoteRouter : .localBroadcast, "",
                           cellular
                               ? "\(profile.deviceName) can only be woken from home until a way in from outside is set up."
                               : "Waking \(profile.deviceName) is not set up yet.")
        }

        var last = WakeOutcome.failed(order[0], "", "")
        for strategy in order {
            last = await wake(profile, using: strategy)
            if last.sent { return last }
        }

        return last
    }

    private static func explain(_ error: Error, _ profile: WakeProfile, _ strategy: WakeStrategy) -> String {
        let host = strategy == .localBroadcast ? profile.broadcast : profile.remoteHost

        if let mine = error as? WakeSendError {
            switch mine {
            case .cannotResolve: return "\(host) could not be looked up."
            case .system(ENETUNREACH), .system(EHOSTUNREACH):
                return "There is no route to \(host) from this network."
            case .system: return mine.errorDescription ?? "The network refused it."
            }
        }

        if let network = error as? NWError {
            switch network {
            case .dns: return "\(host) could not be looked up."
            case .posix(.ENETUNREACH), .posix(.EHOSTUNREACH):
                return "There is no route to \(host) from this network."
            default: return network.localizedDescription
            }
        }

        return error.localizedDescription
    }

    /// One packet, over UDP, with broadcast allowed.
    ///
    /// A BSD socket rather than `NWConnection`, and the reason is `SO_BROADCAST`. A datagram
    /// addressed to a subnet's broadcast address is refused by the kernel outright without that
    /// option set, and Network.framework does not expose it. This is the one place in the app that
    /// reaches past it, for the one thing it cannot express.
    ///
    /// The name is resolved to IPv4 deliberately. There is no such thing as a broadcast address in
    /// IPv6, and a home router forwarding a port to a broadcast address is an IPv4 arrangement
    /// throughout; asking for an IPv6 answer here would give an address the packet could not use.
    static let udp: Send = { packet, host, port in
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)

        var found: UnsafeMutablePointer<addrinfo>?
        let looked = getaddrinfo(host, String(port), &hints, &found)

        guard looked == 0, let first = found else { throw WakeSendError.cannotResolve(host) }
        defer { freeaddrinfo(found) }

        let handle = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard handle >= 0 else { throw WakeSendError.system(errno) }
        defer { close(handle) }

        var allow: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &allow, socklen_t(MemoryLayout<Int32>.size))

        let written = packet.withUnsafeBytes { bytes in
            sendto(handle, bytes.baseAddress, packet.count, 0, first.pointee.ai_addr, first.pointee.ai_addrlen)
        }

        guard written == packet.count else { throw WakeSendError.system(errno) }
    }
}

/// What can go wrong putting a wake packet on the network.
enum WakeSendError: LocalizedError, Equatable {
    case cannotResolve(String)
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .cannotResolve(let host): return "\(host) could not be looked up."
        case .system(let code): return String(cString: strerror(code))
        }
    }
}
