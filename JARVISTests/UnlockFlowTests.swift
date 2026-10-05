import LocalAuthentication
import XCTest
@testable import JARVIS

/// What the phone offers, and what it says when it cannot.
///
/// The unlock flow itself needs a paired PC and a face, so what is held here is everything that
/// decides *whether to offer at all* and *what to say afterwards* - which is where the mistakes
/// that matter live. A button that appears when it cannot work, and a refusal that reads as a
/// different refusal, are both worse than the unlock simply not happening.
final class UnlockFlowTests: XCTestCase {
    private func report(
        session: MachineReport.Session = .locked,
        desktop: Bool = false,
        unlock: UnlockReadiness = .ready,
        because: String? = nil
    ) -> MachineReport {
        MachineReport(machine: "ADMIN", session: session, described: "locked",
                      desktopRunning: desktop, unlock: unlock, unlockBecause: because,
                      at: Date())
    }

    // MARK: when the button belongs on screen

    func testALockedPCWithACredentialOffersAnUnlock() {
        XCTAssertTrue(PCStanding.of(report(), paired: true).offersUnlock)
    }

    func testAPCWithNobodySignedInOffersAnUnlock() {
        XCTAssertTrue(PCStanding.of(report(session: .nobodySignedIn), paired: true).offersUnlock)
    }

    func testAPCInUseOffersNothing() {
        XCTAssertFalse(PCStanding.of(report(session: .inUse, desktop: true), paired: true).offersUnlock)
    }

    func testAnUnreachablePCOffersNothing() {
        XCTAssertFalse(PCStanding.of(nil, paired: true).offersUnlock)
    }

    func testAnUnpairedPCOffersNothing() {
        XCTAssertFalse(PCStanding.of(report(), paired: false).offersUnlock)
        XCTAssertEqual(PCStanding.of(report(), paired: false).availability, .notPaired)
    }

    func testALockedPCWithNoCredentialDoesNotOfferAnUnlockItCannotDo() {
        let standing = PCStanding.of(report(unlock: .notEnrolled), paired: true)

        XCTAssertFalse(standing.offersUnlock)
        XCTAssertEqual(standing.availability, .locked, "the machine is still locked; only the unlock is unavailable")
    }

    func testAPCNeedingReEnrolmentDoesNotOfferAnUnlockAndSaysWhy() {
        let standing = PCStanding.of(report(unlock: .needsReEnrolment), paired: true)

        XCTAssertFalse(standing.offersUnlock)
        XCTAssertEqual(standing.obstacle, "This PC's saved Windows credential needs enrolling again.")
    }

    /// A service too old to describe itself must not silently remove the feature. Offering and
    /// being refused is recoverable; a button that vanished for no visible reason is not.
    func testAServiceThatDoesNotSayIsStillWorthTrying() {
        XCTAssertTrue(PCStanding.of(report(unlock: .unknown), paired: true).offersUnlock)
        XCTAssertNil(PCStanding.of(report(unlock: .unknown), paired: true).obstacle)
    }

    func testAnOlderServiceReadsAsUnknownRatherThanUnsupported() {
        let body: [String: Any] = ["machine": "ADMIN", "session": "Locked", "desktop": "not running"]
        let read = MachineReport.read(body)

        XCTAssertEqual(read?.unlock, .unknown)
    }

    func testReadinessIsReadFromTheService() {
        let body: [String: Any] = [
            "machine": "ADMIN", "session": "Locked", "desktop": "not running",
            "unlock": "needsReEnrolment", "unlockBecause": "Windows refused the stored credential"
        ]

        XCTAssertEqual(MachineReport.read(body)?.unlock, .needsReEnrolment)
        XCTAssertEqual(MachineReport.read(body)?.unlockBecause, "Windows refused the stored credential")
    }

    // MARK: a desktop that has not come up is not the same as a locked machine

    func testAnInUseMachineWithoutJarvisIsNotCalledOnline() {
        XCTAssertEqual(PCAvailability.of(report(session: .inUse, desktop: false), paired: true), .inUse)
        XCTAssertEqual(PCAvailability.of(report(session: .inUse, desktop: true), paired: true), .online)
    }

    // MARK: what the owner is told

    func testCancellingIsNotReportedAsAFailure() {
        XCTAssertTrue(UnlockStop.cancelled.isCancellation)
        XCTAssertFalse(UnlockStop.faceNotRecognised.isCancellation)
        XCTAssertFalse(UnlockStop.needsReEnrolment("x").isCancellation)
    }

    func testThingsThatCannotChangeAreNotWorthPressingAgain() {
        XCTAssertFalse(UnlockStop.notConfigured.worthRetrying)
        XCTAssertFalse(UnlockStop.alreadyInUse.worthRetrying)
        XCTAssertFalse(UnlockStop.needsReEnrolment("x").worthRetrying)
        XCTAssertFalse(UnlockStop.notPaired.worthRetrying)

        XCTAssertTrue(UnlockStop.serviceUnreachable.worthRetrying)
        XCTAssertTrue(UnlockStop.cancelled.worthRetrying)
        XCTAssertTrue(UnlockStop.challenge(.alreadyExpired).worthRetrying)
    }

    /// The brief's rule: never claim Windows let somebody in. These two are the sentences that
    /// would be wrong if anybody ever softened them into "unlock failed".
    func testTheTwoHalvesOfASignInAreDescribedSeparately() {
        XCTAssertTrue(UnlockStop.neverSignedIn.sentence.contains("PIN"))
        XCTAssertTrue(UnlockStop.desktopDidNotStart.sentence.contains("Windows signed in"))
    }

    func testEveryStopSaysSomething() {
        let stops: [UnlockStop] = [
            .cancelled, .biometryUnavailable, .biometryNotEnrolled, .biometryLockedOut,
            .faceNotRecognised, .notPaired, .serviceUnreachable, .notConfigured, .alreadyInUse,
            .challenge(.alreadyExpired), .refused("because"), .needsReEnrolment("because"),
            .neverSignedIn, .desktopDidNotStart
        ]

        for stop in stops {
            XCTAssertFalse(stop.sentence.isEmpty, "\(stop) had nothing to say")
            XCTAssertFalse(stop.sentence.lowercased() == "failed.", "\(stop) said nothing useful")
        }
    }

    // MARK: the stage machine

    func testOnlyAnUnlockInFlightCountsAsBusy() {
        XCTAssertFalse(UnlockStage.idle.busy)
        XCTAssertFalse(UnlockStage.online.busy)
        XCTAssertFalse(UnlockStage.stopped(.cancelled).busy)

        for stage: UnlockStage in [.asking, .faceID, .authorizing, .signingIn, .desktopStarting] {
            XCTAssertTrue(stage.busy, "\(stage) should stop a second tap")
        }
    }

    func testEveryStageInFlightHasSomethingToShow() {
        for stage: UnlockStage in [.asking, .faceID, .authorizing, .signingIn, .desktopStarting, .online] {
            XCTAssertFalse(stage.sentence.isEmpty, "\(stage) had nothing to show")
        }
    }

    // MARK: biometric faults, which used to be one fault

    func testLocalAuthenticationFailuresAreToldApart() {
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.userCancel)), .cancelled)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.appCancel)), .cancelled)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.systemCancel)), .cancelled)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.biometryNotEnrolled)), .biometryNotEnrolled)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.biometryNotAvailable)), .biometryUnavailable)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.biometryLockout)), .biometryLockedOut)
        XCTAssertEqual(DeviceKeys.Failure.reading(LAErrorStub.of(.authenticationFailed)), .didNotMatch)
    }

    /// The regression that prompted this: a phone with no Face ID set up was told it had
    /// cancelled, which is both untrue and unactionable.
    func testNotEnrolledIsNotReportedAsCancelled() {
        let failure = DeviceKeys.Failure.reading(LAErrorStub.of(.biometryNotEnrolled))

        XCTAssertFalse(failure.isCancellation)
        XCTAssertTrue(failure.errorDescription?.contains("set up") == true)
    }
}

/// LAError values cannot be constructed directly; they arrive as NSError from the framework.
private enum LAErrorStub {
    static func of(_ code: LAError.Code) -> Error {
        LAError(code)
    }
}
