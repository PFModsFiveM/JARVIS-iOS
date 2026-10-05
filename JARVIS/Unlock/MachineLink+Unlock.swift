import Foundation
import Network

/// Unlocking Windows from this phone.
///
/// The one request in this app that changes a machine nobody is signed into, so it is the one
/// written most carefully. Three things have to be true at the PC before it will act, and this
/// code can only supply one of them: the connection proves a paired phone, the approval proves
/// the owner's face, and the challenge proves the approval was for *this* machine, *this*
/// account, an unlock, and has not been used. The PC checks all three. Nothing here is trusted.
///
/// **One connection for both requests.** The rest of `MachineLink` connects, asks and hangs up,
/// and this deliberately does not: the challenge lives thirty seconds and the owner's face takes
/// several of them, so a second handshake in the middle would spend the budget on reconnecting.
/// It is also the honest shape - the approval signs this session's transcript, so the challenge
/// and the authorization belong to one conversation.
///
/// **Nothing is claimed that was not observed.** `unlock.authorize` returning "authorized" means
/// the PC accepted the owner's signature; it does not mean Windows let anybody in, and Windows
/// may still refuse. The flow therefore ends by watching the machine's own report until the
/// session says it is in use. If that never happens, it says so, and says the PIN still works.
@MainActor
extension MachineLink {
    /// Where the PC stands and whether to offer to sign into it. Derived from the last report,
    /// never stored, so it cannot disagree with what the machine said.
    var standing: PCStanding { PCStanding.of(report, paired: isPaired) }

    var availability: PCAvailability { standing.availability }

    /// How long to watch for Windows after the PC accepts the authorization.
    ///
    /// Generous, because LSA on a cold logon is not quick, and the cost of being too short is
    /// telling the owner it failed while it is in fact working.
    static let windowsPatience: TimeInterval = 60

    /// How long to then wait for desktop JARVIS. Signing in is the thing that was asked for;
    /// JARVIS starting afterwards is good news that arrives separately and may not arrive at all.
    static let desktopPatience: TimeInterval = 75

    /// How often to ask while watching. Each ask is its own short connection, so this is the one
    /// number that decides how much traffic an unlock costs.
    static let watchEvery: TimeInterval = 1.5

    /// Asks the PC to sign the owner in, with Face ID.
    ///
    /// Returns when there is nothing more to watch - signed in, or stopped with a reason. The
    /// stage is published throughout, so the caller shows progress rather than polling this.
    @discardableResult
    func unlock(now: @escaping () -> Date = Date.init) async -> UnlockStage {
        guard !stage.busy else { return stage }

        guard let paired, let pc = model.pc else { return finish(.stopped(.notPaired)) }

        // Refuse before the connection rather than after it. A PC already in use has nobody
        // locked out, and asking anyway would burn an attempt against the PC's rate limit for a
        // state that is visible from here.
        if availability == .inUse || availability == .online {
            return finish(.stopped(.alreadyInUse))
        }

        enter(.asking)

        let cellular = model.network.cellular
        let candidates = BridgeEndpointResolver.serviceCandidates(
            for: pc, port: paired.port, cellular: cellular, preferLocal: pc.preferLocal ?? true)

        guard !candidates.isEmpty else { return finish(.stopped(.serviceUnreachable)) }

        for candidate in candidates {
            let client = BridgeClient(
                endpoint: candidate.endpoint,
                connectWithin: BridgeEndpointResolver.patience(cellular: cellular),
                patientWhileWaiting: cellular)

            do {
                _ = try await client.resume(deviceId: paired.deviceId, pinnedServerKey: paired.serverKey)

                let outcome = await authorize(over: client, machine: report?.machine, now: now)
                await client.close()

                switch outcome {
                case .stopped(let stop):
                    // A refusal is the PC's answer and the same on every address. Only an
                    // unreachable service is worth another candidate.
                    if stop == .serviceUnreachable { continue }
                    return finish(.stopped(stop))

                case .authorized:
                    return await watchWindows(now: now)
                }
            } catch {
                await client.close()

                if (error as? BridgeError)?.needsPairingAgain == true {
                    return finish(.stopped(.refused(error.localizedDescription)))
                }
            }
        }

        return finish(.stopped(.serviceUnreachable))
    }

    private enum Outcome {
        case authorized
        case stopped(UnlockStop)
    }

    /// Challenge, face, authorization - on the one connection.
    private func authorize(over client: BridgeClient, machine: String?, now: @escaping () -> Date) async -> Outcome {
        let reply: BridgeMessage

        do {
            reply = try await client.request("unlock.challenge", timeout: 12)
        } catch {
            return .stopped(.serviceUnreachable)
        }

        guard reply.kind == "unlock.challenge" else {
            return .stopped(refusal(reply))
        }

        let challenge: UnlockChallenge

        switch UnlockChallenge.read(reply.body, machine: machine, now: now()) {
        case .success(let read): challenge = read
        case .failure(let fault): return .stopped(.challenge(fault))
        }

        enter(.faceID)

        let approved: BridgeMessage

        do {
            approved = try await client.approvedRequest(
                "unlock.authorize",
                reason: "Sign in to \(challenge.machineId)",
                [
                    "challengeId": challenge.id,
                    "accountSid": challenge.accountSid,
                    "protocol": UnlockChallenge.protocolSpoken
                ])
        } catch let failure as DeviceKeys.Failure {
            return .stopped(biometric(failure))
        } catch {
            // The face succeeded and the request did not arrive. The challenge is left to expire
            // rather than retried: an authorization this phone cannot confirm was received is
            // exactly the thing that must not be sent twice.
            return .stopped(.serviceUnreachable)
        }

        // Checked after the round trip, because the owner's face took time and the PC's own
        // clock is the one that decides. Said separately so it reads as the race it is.
        if !challenge.live(at: now()) && approved.kind != "unlock.authorize" {
            return .stopped(.challenge(.alreadyExpired))
        }

        guard approved.kind == "unlock.authorize", approved.body["authorized"] as? Bool == true else {
            return .stopped(refusal(approved))
        }

        enter(.authorizing)
        return .authorized
    }

    /// Watches the machine until Windows has actually done something.
    ///
    /// The brief's rule, and the one worth not getting wrong: authorization is not a sign-in.
    private func watchWindows(now: @escaping () -> Date) async -> UnlockStage {
        enter(.signingIn)

        let signedInBy = now().addingTimeInterval(Self.windowsPatience)

        while now() < signedInBy {
            try? await Task.sleep(nanoseconds: UInt64(Self.watchEvery * 1_000_000_000))

            guard let seen = await ask(force: true) else { continue }

            if seen.session == .inUse {
                if seen.desktopRunning { return finish(.online) }

                enter(.desktopStarting)
                return await watchDesktop(now: now)
            }
        }

        // Windows was authorized and never signed anybody in. Not called a failure, because the
        // owner's PIN is still there and the useful thing to say is which half did not happen.
        //
        // The machine may now know more than it did at the start: Windows refusing the stored
        // credential is what marks it for re-enrolment, and that mark appears in the status reply
        // only after the attempt. Asking once more is the difference between "nothing happened"
        // and the actual reason.
        if let last = report, last.unlock == .needsReEnrolment {
            return finish(.stopped(.needsReEnrolment(last.unlockBecause ?? "Windows would not accept it.")))
        }

        return finish(.stopped(.neverSignedIn))
    }

    private func watchDesktop(now: @escaping () -> Date) async -> UnlockStage {
        let upBy = now().addingTimeInterval(Self.desktopPatience)

        while now() < upBy {
            try? await Task.sleep(nanoseconds: UInt64(Self.watchEvery * 1_000_000_000))

            if let seen = await ask(force: true), seen.desktopRunning { return finish(.online) }
        }

        return finish(.stopped(.desktopDidNotStart))
    }

    /// Reads a refusal the PC sent, keeping its words.
    ///
    /// The PC writes these sentences and this does not rewrite them: there is one copy of each
    /// reason, on the side that knows which one is true, and a phone that paraphrases is a phone
    /// that will eventually paraphrase something into the opposite of what happened.
    private func refusal(_ reply: BridgeMessage) -> UnlockStop {
        let said = reply.text("message") ?? "That could not be done."

        if reply.body["reEnrol"] as? Bool == true { return .needsReEnrolment(said) }
        if said.localizedCaseInsensitiveContains("not set up") { return .notConfigured }
        if said.localizedCaseInsensitiveContains("in use") { return .alreadyInUse }

        if let refused = reply.text("refusal") {
            switch refused {
            case "Expired": return .challenge(.alreadyExpired)
            case "WrongMachine", "WrongAccount", "WrongAction", "WrongProtocol":
                return .challenge(.notAChallenge(said))
            default: break
            }
        }

        return .refused(said)
    }

    private func biometric(_ failure: DeviceKeys.Failure) -> UnlockStop {
        switch failure {
        case .cancelled: return .cancelled
        case .biometryUnavailable: return .biometryUnavailable
        case .biometryNotEnrolled: return .biometryNotEnrolled
        case .biometryLockedOut: return .biometryLockedOut
        case .didNotMatch: return .faceNotRecognised
        case .accessControl, .failed: return .refused(failure.errorDescription ?? "Face ID failed.")
        }
    }

    @discardableResult
    private func finish(_ ending: UnlockStage) -> UnlockStage {
        enter(ending)
        return ending
    }
}
