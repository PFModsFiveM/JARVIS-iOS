import CryptoKit
import Foundation
import Network

/// One request, response or push inside the encrypted session.
/// `@unchecked Sendable`: the body is JSON from `JSONSerialization` and is never mutated after it is made.
struct BridgeMessage: @unchecked Sendable {
    let kind: String
    let id: String
    let body: [String: Any]

    func text(_ key: String) -> String? { body[key] as? String }
    func object(_ key: String) -> [String: Any]? { body[key] as? [String: Any] }
    var message: String { text("message") ?? text("reason") ?? kind }
}

enum BridgeError: LocalizedError {
    case refused(String)
    case closed
    case timedOut
    case serverNotTrusted
    case authenticationFailed
    case pairingDeclined(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .refused(let reason): return "The PC refused: \(reason)."
        case .closed: return "The connection to the PC closed."
        case .timedOut: return "The PC did not answer in time."
        case .serverNotTrusted: return "That PC is not the one this phone paired with. If you reinstalled JARVIS, forget it and pair again."
        case .authenticationFailed: return "The PC no longer recognises this phone. Pair again."
        case .pairingDeclined(let reason): return "Pairing didn't finish: \(reason)."
        case .malformed: return "The PC sent something unexpected."
        }
    }
}

/// The phone's end of the bridge: a WebSocket over Network.framework (so a Bonjour service can be connected to
/// directly), the version 2 handshake, and encrypted requests. Mirrors `BridgeConnection.cs`.
actor BridgeClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "jarvis.bridge.connection")

    private var transcript = Data()
    private var sendKey = Data()
    private var receiveKey = Data()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var pending: [String: CheckedContinuation<BridgeMessage, Error>] = [:]
    private var reading: Task<Void, Never>?
    private var closed = false

    private(set) var shortAuthenticationString = ""
    private(set) var serverKey = Data()

    /// Pushes from the PC (security events). Called off the main actor.
    private var onPush: (@Sendable (BridgeMessage) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?

    init(endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 1 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func setHandlers(push: @escaping @Sendable (BridgeMessage) -> Void, close: @escaping @Sendable (Error?) -> Void) {
        onPush = push
        onClose = close
    }

    // MARK: connecting

    /// Pairs with a PC. `showDigits` is called with the six digits as soon as they exist; the user compares them
    /// with the PC's screen, and the PC's user says yes. Returns the new device id and the PC's key to pin.
    func pair(code: String, deviceName: String, showDigits: @escaping @Sendable (String) -> Void) async throws -> (deviceId: String, serverKey: Data) {
        try await open()
        try await handshake(mode: "pair", deviceId: "", pinned: nil)
        showDigits(shortAuthenticationString)

        let identity = try DeviceKeys.identity()
        let approvalKey = try DeviceKeys.approvalPublicKey()
        let signature = try identity.sign(BridgeCrypto.signed("client", transcript: transcript, detail: "pair"))

        let id = UUID().uuidString.lowercased()
        try await sendEncrypted(kind: "pair.request", id: id, body: [
            "code": code.uppercased().trimmingCharacters(in: .whitespaces),
            "deviceName": deviceName,
            "platform": "iOS",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
            "identityKey": identity.publicKeyX963.base64EncodedString(),
            "approvalKey": approvalKey.base64EncodedString(),
            "signature": signature.base64EncodedString()
        ])

        // pair.waiting, then pair.accepted or pair.declined once the user decides on the PC.
        while true {
            let message = try await receiveEncrypted()
            switch message.kind {
            case "pair.waiting":
                continue
            case "pair.accepted":
                guard let deviceId = message.text("deviceId"),
                      let key = message.text("serverKey").flatMap({ Data(base64Encoded: $0) }),
                      key == serverKey else { throw BridgeError.malformed }
                close()
                return (deviceId, key)
            case "pair.declined":
                close()
                throw BridgeError.pairingDeclined(message.text("reason") ?? "declined")
            default:
                throw BridgeError.malformed
            }
        }
    }

    /// Connects as an already-paired phone: the PC must present the pinned key, and this phone proves its identity key.
    func resume(deviceId: String, pinnedServerKey: Data) async throws -> String {
        try await open()
        try await handshake(mode: "resume", deviceId: deviceId, pinned: pinnedServerKey)

        let identity = try DeviceKeys.identity()
        let signature = try identity.sign(BridgeCrypto.signed("client", transcript: transcript, detail: deviceId))
        let id = UUID().uuidString.lowercased()
        try await sendEncrypted(kind: "auth", id: id, body: ["signature": signature.base64EncodedString()])

        let reply = try await receiveEncrypted()
        guard reply.kind == "auth.ok" else {
            close()
            throw BridgeError.authenticationFailed
        }

        reading = Task { await self.readLoop() }
        return reply.text("name") ?? "iPhone"
    }

    // MARK: requests

    func request(_ kind: String, _ body: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> BridgeMessage {
        try await request(kind, id: UUID().uuidString.lowercased(), body, timeout: timeout)
    }

    /// A request that needs Face ID: the approval key signs this session's transcript, the action and the request id,
    /// so the approval cannot be replayed on another request or another connection.
    func approvedRequest(_ kind: String, reason: String, _ body: [String: Any] = [:]) async throws -> BridgeMessage {
        let id = UUID().uuidString.lowercased()
        let approval = try await DeviceKeys.approve(BridgeCrypto.signed("approve", transcript: transcript, detail: kind + "\n" + id), reason: reason)
        var signedBody = body
        signedBody["approval"] = approval.base64EncodedString()
        return try await request(kind, id: id, signedBody)
    }

    private func request(_ kind: String, id: String, _ body: [String: Any], timeout: TimeInterval = 30) async throws -> BridgeMessage {
        guard !closed else { throw BridgeError.closed }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.sendEncrypted(kind: kind, id: id, body: body)
                } catch {
                    await self.fail(id, error)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.fail(id, BridgeError.timedOut)
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func close() {
        guard !closed else { return }
        closed = true
        reading?.cancel()
        connection.cancel()
        for (_, continuation) in pending { continuation.resume(throwing: BridgeError.closed) }
        pending.removeAll()
    }

    var isOpen: Bool { !closed }

    // MARK: the handshake

    private func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    Task { await self?.closedByNetwork(error) }
                case .waiting(let error):
                    // No route yet (Wi-Fi off, PC asleep): give up rather than wait forever.
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: BridgeError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func closedByNetwork(_ error: Error?) {
        guard !closed else { return }
        close()
        onClose?(error)
    }

    private func handshake(mode: String, deviceId: String, pinned: Data?) async throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let clientEphemeral = ephemeral.publicKey.x963Representation
        var clientNonce = Data(count: BridgeCrypto.nonceBytes)
        let status = clientNonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, BridgeCrypto.nonceBytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BridgeError.malformed }

        let hello: [String: Any] = [
            "type": "client.hello", "protocol": BridgeCrypto.protocolVersion, "mode": mode, "deviceId": deviceId,
            "ephemeralKey": clientEphemeral.base64EncodedString(), "nonce": clientNonce.base64EncodedString()
        ]
        try await sendFrame(try JSONSerialization.data(withJSONObject: hello), text: true)

        let (data, isText) = try await receiveFrame()
        guard isText, let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.malformed }

        if reply["type"] as? String == "server.refused" {
            close()
            throw BridgeError.refused(reply["reason"] as? String ?? "no reason given")
        }

        guard reply["type"] as? String == "server.hello",
              let serverEphemeral = (reply["ephemeralKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let serverNonce = (reply["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let key = (reply["serverKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let signature = (reply["signature"] as? String).flatMap({ Data(base64Encoded: $0) }),
              serverNonce.count == BridgeCrypto.nonceBytes else { throw BridgeError.malformed }

        let transcript = BridgeCrypto.transcript(clientEphemeral: clientEphemeral, clientNonce: clientNonce,
                                                 serverEphemeral: serverEphemeral, serverNonce: serverNonce,
                                                 serverStatic: key, mode: mode, deviceId: deviceId)

        guard BridgeCrypto.verify(publicKeyX963: key, data: BridgeCrypto.signed("server", transcript: transcript), derSignature: signature) else {
            close()
            throw BridgeError.serverNotTrusted
        }

        if let pinned, pinned != key {
            close()
            throw BridgeError.serverNotTrusted
        }

        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: serverEphemeral))
            .withUnsafeBytes { Data($0) }
        let keys = BridgeCrypto.trafficKeys(sharedSecret: secret, transcript: transcript)

        self.transcript = transcript
        self.sendKey = keys.clientToServer
        self.receiveKey = keys.serverToClient
        self.serverKey = key
        self.shortAuthenticationString = BridgeCrypto.shortAuthenticationString(sharedSecret: secret, transcript: transcript)
        sendCounter = 0
        receiveCounter = 0
    }

    // MARK: frames

    private func readLoop() async {
        while !Task.isCancelled && !closed {
            do {
                let message = try await receiveEncrypted()
                if let continuation = pending.removeValue(forKey: message.id) {
                    continuation.resume(returning: message)
                } else {
                    onPush?(message)
                }
            } catch {
                closedByNetwork(error)
                return
            }
        }
    }

    private func sendEncrypted(kind: String, id: String, body: [String: Any]) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["kind": kind, "id": id, "body": body])
        // Sealed and handed to the connection with no suspension in between, so counters go out in order.
        let frame = try BridgeCrypto.seal(key: sendKey, direction: BridgeCrypto.clientToServer, counter: sendCounter, plaintext: json, transcript: transcript)
        sendCounter += 1
        try await sendFrame(frame, text: false)
    }

    private func receiveEncrypted() async throws -> BridgeMessage {
        let (frame, isText) = try await receiveFrame()
        guard !isText,
              let plain = BridgeCrypto.open(key: receiveKey, direction: BridgeCrypto.serverToClient, expectedCounter: receiveCounter, frame: frame, transcript: transcript) else {
            close()
            throw BridgeError.malformed
        }
        receiveCounter += 1

        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let kind = object["kind"] as? String else { throw BridgeError.malformed }
        return BridgeMessage(kind: kind, id: object["id"] as? String ?? "", body: object["body"] as? [String: Any] ?? [:])
    }

    private func sendFrame(_ data: Data, text: Bool) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receiveFrame() async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                      metadata.opcode != .close else {
                    continuation.resume(throwing: BridgeError.closed)
                    return
                }
                continuation.resume(returning: (data ?? Data(), metadata.opcode == .text))
            }
        }
    }
}
