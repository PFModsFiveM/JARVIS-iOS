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

    /// A SwitchBot Bot pressing the PC's own power button, through SwitchBot's cloud.
    ///
    /// Not a magic packet at all, and the only one of the three that works from anywhere: a
    /// broadcast cannot leave a phone on mobile data, and the router route needs a way in from
    /// outside that most houses do not have. This goes phone to SwitchBot's cloud to the hub at
    /// home to the Bot over Bluetooth, and the PC takes no part in it - which is the point, since
    /// at that moment the PC is off.
    ///
    /// Last in the order on purpose. It is the slowest, it spends the account's daily quota, and
    /// it physically presses a button; a packet that wakes a machine that was only asleep is
    /// cheaper and gentler than that, so it is tried first whenever it can work.
    case powerButton
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
///
/// Everything here is something this phone did or saw. The one thing it cannot see - whether a
/// packet crossed the internet, reached the router, was forwarded to the home network and was heard
/// by the card - is exactly what a wake from outside most often fails at, so the advice built from
/// this says what is known and names what is not, rather than guessing which part failed.
struct WakeOutcome: Equatable {
    var sent: Bool
    var strategy: WakeStrategy
    var destination: String
    var packets: Int
    /// One sentence a person can read. Empty when it worked.
    var because: String
    /// The name or address the packets were addressed to, as configured.
    var host: String = ""
    var port: UInt16 = 0
    /// The IPv4 address a remote name resolved to before sending, when it was looked up here. Nil
    /// for a home broadcast, which is already an address.
    var resolved: String? = nil
    var at: Date = Date()

    static func failed(_ strategy: WakeStrategy, _ destination: String, _ because: String) -> WakeOutcome {
        WakeOutcome(sent: false, strategy: strategy, destination: destination, packets: 0, because: because)
    }

    /// The facts of this attempt, one per line, for the diagnostics screen. No claim about the PC.
    var evidence: [String] {
        var lines = ["Route: " + (strategy == .localBroadcast ? "home broadcast (on the home network)" : "through the router (from outside)")]

        if strategy == .remoteRouter {
            lines.append("Remote host: " + (host.isEmpty ? "not set" : "configured"))
            if let resolved {
                lines.append("DNS: resolved to \(resolved) (IPv4)")
            } else if sent {
                lines.append("DNS: resolved by iOS while sending")
            }
        }

        lines.append("UDP port: \(port)")
        lines.append(sent ? "\(packets) magic packets handed to iOS" : "Nothing sent: \(because)")
        lines.append("At: " + at.formatted(date: .abbreviated, time: .standard))

        if sent {
            lines.append("Delivery: unconfirmed. Nothing acknowledges a magic packet, so whether it reached the router, the home network or the card is not known here.")
        }

        return lines
    }

    /// What to say when the packets went and JARVIS never answered, from what is actually known.
    ///
    /// It does not say the router got the packet, or that the card did, or that the PC failed to wake:
    /// all this phone knows is that it handed the packets to iOS and nothing answered afterwards.
    func noAnswerAdvice(waited seconds: Int) -> String {
        let count = "\(packets) magic packet\(packets == 1 ? "" : "s")"

        if strategy == .localBroadcast {
            return "\(count) went to the home broadcast address (\(host):\(port)) and JARVIS did not come online within \(seconds) s. Delivery on the home network cannot be confirmed either. Check that the Ethernet card is allowed to wake the PC (Device Manager › the card › Power Management), that Wake on Magic Packet is on in its Advanced tab, and that Wake-on-LAN is enabled in the BIOS. Wake-on-LAN over Wi-Fi usually does not work; it needs the wired card."
        }

        let lookedUp = resolved.map { " The name resolved to \($0)." } ?? ""

        return "\(count) went to the configured dynamic-DNS name on UDP \(port) and JARVIS did not come online within \(seconds) s.\(lookedUp) Whether they reached the router, were forwarded to the home network or were heard by the card cannot be confirmed from here. Check, in order: that the PC wakes from a wake sent at home; that the router forwards UDP \(port) to the home broadcast address; that the home connection has a public IPv4 address (not CGNAT); and that the router allows forwarding to a broadcast address - many do not. With the PC awake, Diagnostics can test the route into the house."
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

    /// Looks a remote name up to one IPv4 address before sending, so the attempt can say what the
    /// name resolved to. Nil means it was not looked up here and the send resolves it itself.
    typealias Resolve = @Sendable (String) async throws -> String?

    private let send: Send
    private let resolve: Resolve

    init(send: @escaping Send = WakeOnLanService.udp, resolve: @escaping Resolve = WakeOnLanService.notLookedUp) {
        self.send = send
        self.resolve = resolve
    }

    /// Leaves the name to the send. The default, so a test's fake send is never preceded by a real lookup.
    static let notLookedUp: Resolve = { _ in nil }

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
    static func strategies(for profile: WakeProfile, cellular: Bool, powerButton: Bool = PcPowerBot.isSetUp) -> [WakeStrategy] {
        var order: [WakeStrategy] = []

        if !cellular && profile.usable { order.append(.localBroadcast) }
        if profile.reachableRemotely && (!cellular || profile.overCellular) { order.append(.remoteRouter) }

        // Always last, and always available once the PC has handed the button over - it is the
        // only one that does not need this phone to be able to reach the house's network.
        if powerButton { order.append(.powerButton) }

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

        let at = Date()
        var resolved: String?

        // A remote name is looked up once, before anything is sent, so the attempt can say what it
        // resolved to - the first fact worth knowing when a wake from outside does nothing.
        if strategy == .remoteRouter {
            do {
                resolved = try await resolve(host)
            } catch {
                var failed = WakeOutcome.failed(strategy, destination, Self.explain(error, profile, strategy))
                failed.host = host
                failed.port = port
                failed.at = at
                return failed
            }
        }

        let packet = mac.magicPacket
        var sent = 0

        for attempt in 0..<Self.burst {
            if attempt > 0 { try? await Task.sleep(for: Self.betweenPackets) }
            do {
                try await send(packet, resolved ?? host, port)
                sent += 1
            } catch {
                // The first failure is the answer: a name that will not resolve resolves no better
                // twice, and a network with no route to that address has none on the second try.
                var failed = WakeOutcome.failed(strategy, destination, Self.explain(error, profile, strategy))
                failed.host = host
                failed.port = port
                failed.resolved = resolved
                failed.at = at
                return failed
            }
        }

        return WakeOutcome(sent: true, strategy: strategy, destination: destination, packets: sent, because: "",
                           host: host, port: port, resolved: resolved, at: at)
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
                               ? "\(profile.deviceName) can only be woken from home until a way in from outside is set up, or a Bot is put on its power button."
                               : "Waking \(profile.deviceName) is not set up yet.")
        }

        var last = WakeOutcome.failed(order[0], "", "")
        for strategy in order {
            last = strategy == .powerButton ? await pressThePowerButton() : await wake(profile, using: strategy)
            if last.sent { return last }
        }

        return last
    }

    /// The last resort, and the only one that is not a packet.
    ///
    /// Kept here rather than in `wake(_:using:)` because that method is about magic packets -
    /// addresses, ports and broadcast - and none of those words mean anything to a Bot on a
    /// button. Same shape of answer, so the caller does not care which happened.
    private func pressThePowerButton() async -> WakeOutcome {
        guard let name = PcPowerBot.buttonName else {
            return .failed(.powerButton, "", "No power button has been handed to this phone.")
        }

        do {
            _ = try await PcPowerBot.press()

            // because is empty when it worked, as every other outcome here is.
            return WakeOutcome(sent: true, strategy: .powerButton, destination: name, packets: 1, because: "")
        } catch {
            return .failed(.powerButton, name, error.localizedDescription)
        }
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

extension WakeOnLanService {
    /// One IPv4 address for a name, as text. A literal address is returned as it is.
    ///
    /// IPv4 only, as `udp` is: a router forwarding a port to a broadcast address is an IPv4 arrangement
    /// throughout. A name with no IPv4 record is reported as not resolving, because for this purpose
    /// it does not.
    static let ipv4: Resolve = { host in
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)

        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { throw WakeSendError.cannotResolve(host) }
        defer { freeaddrinfo(found) }
        guard let raw = first.pointee.ai_addr else { throw WakeSendError.cannotResolve(host) }

        var address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
            throw WakeSendError.cannotResolve(host)
        }

        return String(cString: text)
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
